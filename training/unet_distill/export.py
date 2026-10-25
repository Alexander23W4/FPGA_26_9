"""Export a trained candidate, with folded FP32 and per-output-channel INT8 weights.

These are independent student artifacts, not replacements for the current U-Net
RTL program. INT8 weights are evaluated after dequantization; activations remain
FP32. An integer inference engine/QAT is a separate subsequent step.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image, ImageDraw
import torch
from torch import nn
from torch.fx import symbolic_trace
from torch.nn.utils.fusion import fuse_conv_bn_eval
from torch.utils.data import DataLoader

from models import ROOT, Student, profile
from train import CachedFrames, evaluate, metrics


def folded(model):
    model = copy.deepcopy(model).eval()
    for module in model.modules():
        if isinstance(module, nn.Sequential) and len(module) >= 2:
            if isinstance(module[0], nn.Conv2d) and isinstance(module[1], nn.BatchNorm2d):
                module[0] = fuse_conv_bn_eval(module[0], module[1])
                module[1] = nn.Identity()
    if any(isinstance(m, nn.BatchNorm2d) for m in model.modules()):
        raise ValueError("Unfolded BatchNorm remains")
    return model


def serialize(model, out):
    quant = copy.deepcopy(model)
    q_modules = dict(quant.named_modules())
    fp, q = bytearray(), bytearray()
    layers = []
    for name, layer in model.named_modules():
        if not isinstance(layer, nn.Conv2d):
            continue
        weights = layer.weight.detach().cpu().numpy().astype("<f4")
        bias = layer.bias.detach().cpu().numpy().astype("<f4")
        maximum = np.abs(weights).reshape(weights.shape[0], -1).max(1)
        scale = np.where(maximum > 0, maximum / 127, 1).astype("<f4")
        ints = np.clip(np.rint(weights / scale[:, None, None, None]), -127, 127).astype(np.int8)
        offset_fp, offset_q = len(fp), len(q)
        fp.extend(weights.tobytes())
        fp.extend(bias.tobytes())
        q.extend(ints.tobytes())
        while len(q) % 4:
            q.append(0)
        scale_offset = len(q)
        q.extend(scale.tobytes())
        bias_offset = len(q)
        q.extend(bias.tobytes())
        with torch.no_grad():
            q_modules[name].weight.copy_(torch.from_numpy(ints.astype(np.float32) * scale[:, None, None, None]))
        layers.append({"name": name, "shape_oihw": list(weights.shape), "groups": layer.groups,
                       "stride": list(layer.stride), "padding": list(layer.padding),
                       "fp32_weight_offset_bytes": offset_fp, "int8_weight_offset_bytes": offset_q,
                       "weight_elements": weights.size, "int8_scale_offset_bytes": scale_offset,
                       "int8_bias_offset_bytes": bias_offset})
    for name, contents in (("weights_fp32.bin", fp), ("weights_int8.bin", q)):
        (out / name).write_bytes(contents)
    manifest = {"format": "tiny_depthwise_unet_v1", "width": model.width,
                "input": "NCHW float32 gray/255, 1x1x256x256", "output": "1x5x256x256 logits; argmax over channels",
                "class_mapping": ["background", "LA_provisional", "RA_provisional", "LV_provisional", "RV_provisional"],
                "activations_quantized": False, "int8_scheme": "symmetric per-output-channel; int8[-127,127]; float32 bias/scale",
                "byte_order": "little", "layers": layers,
                "files": {name: {"bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}
                          for name, blob in (("weights_fp32.bin", fp), ("weights_int8.bin", q))}}
    # Preserve the actual complete operator graph as well as the convolution
    # parameters; upsample/concat/ReLU6 cannot be inferred from weights alone.
    traced = symbolic_trace(model)
    manifest["torch_fx_graph"] = str(traced.graph)
    (out / "model.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return quant, manifest


@torch.inference_mode()
def preview(model, quant, cache, out):
    records = [r for r in json.loads((cache / "samples.json").read_text(encoding="utf-8")) if r["split"] == "test"]
    # Fixed first test samples, not the best-looking predictions.
    chosen = records[:4]
    panel = Image.new("RGB", (256 * 4, 286 * len(chosen)), "white")
    draw = ImageDraw.Draw(panel)
    palette = np.array([[0, 0, 0], [230, 55, 65], [245, 205, 45], [40, 185, 110], [50, 105, 235]], np.uint8)
    for row, record in enumerate(chosen):
        with np.load(cache / record["cache"]) as sample:
            gray = sample["image"]
            x = torch.from_numpy(gray.copy()).float()[None, None] / 255
            labels = [sample["logits"].argmax(0), model(x)[0].argmax(0).numpy(), quant(x)[0].argmax(0).numpy()]
            images = [np.repeat(gray[:, :, None], 3, axis=2)]
            for label in labels:
                rgb = np.repeat(gray[:, :, None], 3, axis=2).astype(float)
                rgb[label > 0] = .45 * rgb[label > 0] + .55 * palette[label[label > 0]]
                images.append(rgb.astype(np.uint8))
            for column, (name, image) in enumerate(zip(("Input", "Original teacher", "Distilled FP32", "INT8 weights / FP32 activations"), images)):
                panel.paste(Image.fromarray(image), (256 * column, 286 * row + 26))
                draw.text((256 * column + 5, 286 * row + 5), name, fill="#27252D")
    panel.save(out / "preview.png")


def export(args):
    torch.set_num_threads(args.threads)
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = Student(state["width"]).eval()
    model.load_state_dict(state["state_dict"])
    args.out.mkdir(parents=True, exist_ok=True)
    torch.save({"architecture": state["architecture"], "width": state["width"],
                "state_dict": model.state_dict(), "configuration": state["configuration"]}, args.out / "student.pt")
    fused = folded(model)
    quant, manifest = serialize(fused, args.out)
    test = DataLoader(CachedFrames(args.cache, "test"), batch_size=4)
    max_error, label_errors, pixels = 0., 0, 0
    with torch.inference_mode():
        for image, _, _ in test:
            a, b = model(image), fused(image)
            max_error = max(max_error, float((a - b).abs().max()))
            label_errors += int((a.argmax(1) != b.argmax(1)).sum())
            pixels += image.shape[0] * 256 * 256
    if max_error > .003 or label_errors > max(4, pixels * 1e-5):
        raise ValueError(f"BatchNorm folding mismatch: {max_error}, {label_errors}")
    result = {"folding_max_logit_error": max_error, "folding_label_mismatches": label_errors,
              "test_pixels": pixels, "fp32_student": evaluate(fused, test, "cpu"),
              "int8_weights_fp32_activations": evaluate(quant, test, "cpu"),
              "files": manifest["files"], "already_supported_by_current_fpga_rtl": False,
              "full_integer_inference_validated": False}
    (args.out / "verification.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    preview(fused, quant, args.cache, args.out)
    print("STUDENT_EXPORT_OK", json.dumps(result), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--cache", type=Path, default=ROOT / "build/unet_distill/cache_patient")
    p.add_argument("--threads", type=int, default=4)
    export(p.parse_args())
