"""Export and independently validate an accuracy-first decoder student."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw
import torch
from torch import nn
from torch.nn import functional as F

from models import ROOT
from decoder_student import DecoderStudent, profile_decoder
from export import folded
from train import CachedFrames, confusion, metrics
sys.path.insert(0, str(ROOT / "rtl/unet/tools"))
from export_model import write_export


def convolution_layers(model):
    for i, op in enumerate(model.encoder.graph["ops"]):
        if op["name"].startswith("decoder."): break
        if op["kind"] in (0, 1):
            yield (f"encoder.{i}", getattr(model.encoder, f"weight_{i}"), getattr(model.encoder, f"bias_{i}"),
                   op["cin"] if op["kind"] == 1 else 1)
    for name, module in model.named_modules():
        if isinstance(module, nn.Conv2d): yield name, module.weight, module.bias, module.groups


def quantize(model, out):
    quant = copy.deepcopy(model)
    dst = {name: (w, b) for name, w, b, _ in convolution_layers(quant)}
    fp, ints, records = bytearray(), bytearray(), []
    for name, weight, bias, groups in convolution_layers(model):
        w = weight.detach().numpy().astype("<f4")
        b = bias.detach().numpy().astype("<f4")
        maximum = np.abs(w).reshape(len(w), -1).max(1)
        scale = np.where(maximum > 0, maximum / 127, 1).astype("<f4")
        q = np.rint(w / scale[:, None, None, None]).clip(-127, 127).astype("i1")
        wf, wq = len(fp), len(ints)
        fp.extend(w.tobytes()); fp.extend(b.tobytes())
        ints.extend(q.tobytes())
        while len(ints) % 4: ints.append(0)
        so = len(ints); ints.extend(scale.tobytes())
        bo = len(ints); ints.extend(b.tobytes())
        with torch.no_grad(): dst[name][0].copy_(torch.from_numpy(q.astype(np.float32) * scale[:, None, None, None]))
        records.append({"name": name, "shape_oihw": list(w.shape), "groups": groups, "elements": w.size,
                        "fp32_offset": wf, "int8_offset": wq, "scale_offset": so, "bias_offset": bo})
    for filename, blob in (("weights_fp32.bin", fp), ("weights_int8.bin", ints)):
        (out / filename).write_bytes(blob)
    manifest = {"architecture": "frozen_original_encoder_narrow_decoder_v1", "decoder_base": model.width,
                "class_ids": {"background": 0, "LA_provisional": 1, "RA_provisional": 2, "LV_provisional": 3, "RV_provisional": 4},
                "layers": records, "INT8_activations": False, "int8_scheme": "per-output-channel symmetric weights; FP32 scale/bias",
                "files": {n: {"bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()} for n, b in
                          (("weights_fp32.bin", fp), ("weights_int8.bin", ints))}}
    (out / "quantization.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return quant, manifest


def export_hls_graph(model, out):
    graph = copy.deepcopy(model.encoder.graph)
    graph.pop("weights_sha256", None)
    graph.pop("program_id", None)
    graph["architecture"] = f"distilled_original_encoder_decoder_{model.widths}"
    graph["teacher_weights_sha256"] = model.encoder.graph["weights_sha256"]
    graph["used_arrays"] = None
    graph["ignored_counters"] = None
    layers = dict((name, (w, b)) for name, w, b, _ in convolution_layers(model))
    blocks, words = [np.zeros(16, "<f4")], 16
    def append(array):
        nonlocal words
        pad = (-words) % 16
        if pad: blocks.append(np.zeros(pad, "<f4")); words += pad
        offset = words
        data = np.asarray(array, "<f4").ravel()
        blocks.append(data); words += data.size
        return offset
    for i, op in enumerate(graph["ops"]):
        source = graph["tensors"][op["src"]]
        destination = graph["tensors"][op["dst"]]
        op["cin"] = source["c"]
        if op["kind"] == 3:
            op["skip_c"] = graph["tensors"][op["skip"]]["c"] if op["skip"] >= 0 else 0
            op["cout"] = op["cin"] + op["skip_c"]
        elif op["kind"] in (0, 1):
            if op["name"].startswith("decoder."):
                _, b, c = op["name"].split(".")
                name = f"blocks.{b}.{int(c[-1])-1}.0"
            elif op["name"] == "segmentation_head": name = "head"
            else: name = f"encoder.{i}"
            weight, bias = layers[name]
            weight, bias = weight.detach().numpy(), bias.detach().numpy()
            op["cout"] = weight.shape[0]
            co, red, ky, kx = weight.shape
            padded = ((co + 15) // 16) * 16
            wp = np.zeros((padded, red, ky, kx), np.float32)
            wp[:co] = weight
            bp = np.zeros(padded, np.float32); bp[:co] = bias
            op["weights"] = append(wp.reshape(-1, 16, red, ky, kx).transpose(0, 3, 4, 2, 1))
            op["bias"] = append(bp)
        else: op["cout"] = source["c"]
        destination["c"] = op["cout"]
    # Reuse DDR only after the final consumer. Original registered gray remains
    # live through final output, just as in the complete model implementation.
    last = {i: -1 for i in range(len(graph["tensors"]))}
    for i, op in enumerate(graph["ops"]):
        for key in ("src", "skip"):
            if op[key] >= 0: last[op[key]] = i
    last[0] = last[graph["logits"]] = len(graph["ops"]) + 1
    free, live, high = [], {}, 0
    def allocate(tid):
        nonlocal high
        t = graph["tensors"][tid]
        size = ((t["h"] * t["w"] * t["c"] + 15) // 16) * 16
        found = next(((i, value) for i, value in enumerate(free) if value[1] >= size), None)
        if found:
            i, (offset, length) = found; free.pop(i)
            if length > size: free.append((offset + size, length - size))
        else: offset = high; high += size
        t["offset"] = offset; live[tid] = (offset, size)
    allocate(0)
    for i, op in enumerate(graph["ops"]):
        allocate(op["dst"])
        for tid in list(live):
            if last[tid] == i: free.append(live.pop(tid))
        free.sort(); merged = []
        for offset, length in free:
            if merged and sum(merged[-1]) == offset: merged[-1] = (merged[-1][0], merged[-1][1] + length)
            else: merged.append((offset, length))
        free = merged
    graph["label_offset"] = high
    graph["workspace_words"] = high + 256 * 256
    graph["weight_words"] = words
    graph["macs_per_frame"] = sum(o["oh"] * o["ow"] * o["cout"] * o["kernel"] ** 2 *
          (1 if o["kind"] == 1 else o["cin"]) for o in graph["ops"] if o["kind"] in (0, 1))
    write_export(out, graph, np.concatenate(blocks).astype("<f4"), out / "model_ops.h")
    return graph


def edges(labels):
    mask = F.one_hot(labels.long(), 5).permute(0, 3, 1, 2).float()[:, 1:]
    p = F.pad(mask, (1, 1, 1, 1))
    interior = p[:, :, :-2, 1:-1] * p[:, :, 2:, 1:-1] * p[:, :, 1:-1, :-2] * p[:, :, 1:-1, 2:]
    return mask * (1 - interior)


@torch.inference_mode()
def evaluate_full(model, dataset):
    matrix = torch.zeros(5, 5, dtype=torch.long)
    sums = torch.zeros(4, 4, dtype=torch.double)
    for image, teacher, _ in torch.utils.data.DataLoader(dataset, batch_size=2):
        actual, expected = model(image).argmax(1), teacher.argmax(1)
        matrix += confusion(actual, expected)
        a, b = edges(actual), edges(expected)
        sums[0] += (a * F.max_pool2d(b, 3, 1, 1)).sum((0, 2, 3)).double()
        sums[1] += (b * F.max_pool2d(a, 3, 1, 1)).sum((0, 2, 3)).double()
        sums[2] += a.sum((0, 2, 3)).double()
        sums[3] += b.sum((0, 2, 3)).double()
    precision, recall = sums[0] / sums[2].clamp_min(1), sums[1] / sums[3].clamp_min(1)
    boundary = 2 * precision * recall / (precision + recall).clamp_min(1e-12)
    result = metrics(matrix)
    result.update({"boundary_f1_tolerance_1px_per_class": boundary.tolist(), "boundary_f1_tolerance_1px_mean": float(boundary.mean())})
    return result


@torch.inference_mode()
def export(args):
    torch.set_num_threads(args.threads)
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = DecoderStudent(state["base"], detail_width=state.get("detail_width", 8)).eval()
    model.load_state_dict(state["state_dict"])
    if state["configuration"].get("hint_weight", 0): model.head.requires_grad_(False)
    args.out.mkdir(parents=True, exist_ok=True)
    torch.save({k: v for k, v in state.items() if k != "optimizer"}, args.out / "student.pt")
    fused = folded(model)
    quant, manifest = quantize(fused, args.out)
    graph = export_hls_graph(fused, args.out / "fp32_hls")
    test = CachedFrames(args.cache, "test")
    image = test[0][0][None]
    fold_error = float((model(image) - fused(image)).abs().max())
    if fold_error > .003: raise ValueError(f"BN folding mismatch: {fold_error}")
    # The independent NumPy interpreter checks the actual emitted HLS weights,
    # graph channel counts, offsets and skip concatenation, not just the NN.
    first = json.loads((args.cache / "samples.json").read_text(encoding="utf-8"))
    first = next(row for row in first if row["split"] == "test")
    with np.load(args.cache / first["cache"]) as sample:
        sample["image"].tofile(args.out / "graph_input.bin")
    from reference import run
    run(args.out / "fp32_hls", args.out / "graph_input.bin", args.out / "numpy_reference")
    expected = np.fromfile(args.out / "numpy_reference.logits", "<f4").reshape(256, 256, 5)
    actual = fused(image)[0].permute(1, 2, 0).numpy()
    if not np.allclose(expected, actual, rtol=2e-3, atol=3e-3): raise ValueError("Emitted HLS graph differs from the trained model")
    error = float(np.abs(expected - actual).max())
    result = {"folding_max_logit_error_first_test_frame": fold_error,
              "export_graph_max_logit_error": error,
              "export_graph_label_mismatches": int((expected.argmax(-1) != actual.argmax(-1)).sum()),
              "fp32_test_teacher": evaluate_full(fused, test), "int8_weights_test_teacher": evaluate_full(quant, test),
              "files": manifest["files"], "profile": profile_decoder(model),
              "fp32_hls_weight_bytes": graph["weight_words"] * 4,
              "workspace_bytes": graph["workspace_words"] * 4,
              "fpga_replaced": False, "activation_integer_inference_validated": False}
    (args.out / "verification.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    panel = Image.new("RGB", (1024, 286 * 4), "white")
    draw = ImageDraw.Draw(panel)
    palette = np.array([[0, 0, 0], [230, 55, 65], [245, 205, 45], [40, 185, 110], [50, 105, 235]], np.uint8)
    for row in range(4):
        image, teacher, _ = test[row]
        gray = (image[0].numpy() * 255).round().astype(np.uint8)
        labels = [teacher.argmax(0).numpy(), fused(image[None])[0].argmax(0).numpy(), quant(image[None])[0].argmax(0).numpy()]
        images = [np.repeat(gray[:, :, None], 3, 2)]
        for label in labels:
            rgb = np.repeat(gray[:, :, None], 3, 2).astype(float)
            rgb[label > 0] = .5 * rgb[label > 0] + .5 * palette[label[label > 0]]
            images.append(rgb.astype(np.uint8))
        for column, (title, pic) in enumerate(zip(("Input", "Original teacher", "Distilled FP32", "INT8 weights / FP32 activations"), images)):
            panel.paste(Image.fromarray(pic), (column * 256, row * 286 + 26))
            draw.text((column * 256 + 5, row * 286 + 5), title, fill="#27252D")
    panel.save(args.out / "preview.png")
    print("DECODER_EXPORT_VERIFIED", json.dumps(result), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--cache", type=Path, default=ROOT / "build/unet_distill/cache_patient")
    p.add_argument("--threads", type=int, default=2)
    export(p.parse_args())
