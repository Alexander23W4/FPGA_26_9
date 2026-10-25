"""Accuracy-first student: preserve the trained encoder, distill a narrow decoder."""
import copy
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from models import ROOT, Teacher, conv_norm


class DecoderStudent(nn.Module):
    def __init__(self, base=32, directory=ROOT / "build/unet/model", detail_width=8):
        super().__init__()
        if base not in (16, 32, 64):
            raise ValueError("Decoder base must be 16, 32 or 64")
        self.width = base
        if detail_width not in (8, 16): raise ValueError("detail_width must be 8 or 16")
        self.detail_width = detail_width
        self.widths = [base, base // 2, max(8, base // 4), 8, detail_width]
        self.encoder = Teacher(directory, encoder_only=True)
        self.blocks = nn.ModuleList()
        ci = 1280
        for sc, co in zip((96, 32, 24, 16, 0), self.widths):
            block = nn.Sequential(conv_norm(ci + sc, co, 3), conv_norm(co, co, 3))
            for norm in block:
                norm[2] = nn.ReLU(inplace=False)
            self.blocks.append(block)
            ci = co
        self.head = nn.Conv2d(ci, 5, 3, padding=1)

    def decode_features(self, features):
        x = features[0]
        for i, block in enumerate(self.blocks):
            x = F.interpolate(x, scale_factor=2, mode="nearest")
            if i < 4:
                x = torch.cat((x, features[i + 1]), dim=1)
            x = block(x)
        return x

    def decode(self, features):
        return self.head(self.decode_features(features))

    def forward(self, image):
        return self.decode(self.encoder(image))

    def initialize_from_teacher(self, directory=ROOT / "build/unet/model"):
        """Retain high-magnitude output filters and their consistent input IDs."""
        teacher = Teacher(directory).eval()
        previous = None
        with torch.no_grad():
            for block_index, block in enumerate(self.blocks):
                for conv_index, norm in enumerate(block):
                    name = f"decoder.{block_index}.conv{conv_index + 1}"
                    op_index = next(i for i, o in enumerate(teacher.graph["ops"]) if o["name"] == name)
                    source = getattr(teacher, f"weight_{op_index}")
                    bias = getattr(teacher, f"bias_{op_index}")
                    if block_index == 0 and conv_index == 0:
                        inputs = torch.arange(source.shape[1])
                    elif conv_index == 0:
                        # Original upsample source width is available directly
                        # from its input tensor, not the prior conv's Cout.
                        up = teacher.graph["ops"][op_index - 1]
                        old_ci = up["cin"]
                        inputs = torch.cat((previous, torch.arange(up["skip_c"]) + old_ci))
                    else:
                        inputs = previous
                    candidates = source[:, inputs]
                    importance = candidates.abs().sum((1, 2, 3))
                    selected = importance.topk(norm[0].out_channels).indices.sort().values
                    norm[0].weight.copy_(candidates[selected])
                    norm[1].running_mean.zero_()
                    norm[1].running_var.fill_(1 - norm[1].eps)
                    norm[1].weight.fill_(1)
                    norm[1].bias.copy_(bias[selected])
                    previous = selected
            index = next(i for i, o in enumerate(teacher.graph["ops"]) if o["name"] == "segmentation_head")
            self.head.weight.copy_(getattr(teacher, f"weight_{index}")[:, previous])
            self.head.bias.copy_(getattr(teacher, f"bias_{index}"))


def profile_decoder(model):
    macs = 381739008
    def count(module, inputs, result):
        nonlocal macs
        macs += result.numel() * module.in_channels * module.kernel_size[0] * module.kernel_size[1]
    handles = [m.register_forward_hook(count) for m in model.modules() if isinstance(m, nn.Conv2d)]
    was_training = model.training
    model.eval()
    with torch.inference_mode():
        model(torch.zeros(1, 1, 256, 256))
    for h in handles: h.remove()
    model.train(was_training)
    weights = sum(p.numel() for p in model.parameters())
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    buffers = sum(b.numel() for b in model.encoder.buffers())
    return {"architecture": "frozen_original_encoder_narrow_decoder_v1", "decoder_base": model.width,
            "decoder_widths": model.widths, "trainable_parameters": trainable,
            "parameter_values": weights,
            "frozen_encoder_values": buffers, "macs_per_frame": macs,
            "mac_reduction": 3373326336 / macs, "estimated_fp32_values_bytes": (weights + buffers) * 4,
            "hardware_fps_measured": False}


def cache_features(cache, threads=2):
    torch.set_num_threads(threads)
    encoder = Teacher(encoder_only=True).eval()
    samples = json.loads((cache / "samples.json").read_text(encoding="utf-8"))
    config = json.loads((cache / "configuration.json").read_text(encoding="utf-8"))
    destination = cache / "encoder_features"
    destination.mkdir(exist_ok=True)
    fingerprint = destination / "teacher.json"
    expected = {"teacher_sha256": config["teacher_sha256"], "features": encoder.feature_ids}
    if fingerprint.exists() and json.loads(fingerprint.read_text(encoding="utf-8")) != expected:
        raise ValueError("Encoder cache belongs to a different teacher")
    fingerprint.write_text(json.dumps(expected), encoding="utf-8")
    begin = time.perf_counter()
    for i, row in enumerate(samples):
        path = destination / row["cache"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            with np.load(cache / row["cache"]) as item:
                image = torch.from_numpy(item["image"].copy()).float()[None, None] / 255
                with torch.inference_mode(): features = encoder(image)
                np.savez(path, **{f"f{j}": f[0].numpy().astype(np.float16) for j, f in enumerate(features)})
        if (i + 1) % 50 == 0 or i + 1 == len(samples):
            print(f"ENCODER_CACHE {i+1}/{len(samples)} seconds={time.perf_counter()-begin:.1f}", flush=True)


def cache_hints(cache, threads=2):
    torch.set_num_threads(threads)
    teacher = Teacher(last_feature=True).eval()
    samples = json.loads((cache / "samples.json").read_text(encoding="utf-8"))
    rows = [r for r in samples if r["split"] == "train"]
    destination = cache / "teacher_last16"
    destination.mkdir(exist_ok=True)
    expected = {"teacher_sha256": teacher.graph["weights_sha256"], "target": "final decoder ReLU feature, before 5-class head"}
    manifest = destination / "teacher.json"
    if manifest.exists() and json.loads(manifest.read_text(encoding="utf-8")) != expected:
        raise ValueError("Teacher hint cache differs")
    manifest.write_text(json.dumps(expected), encoding="utf-8")
    begin = time.perf_counter()
    for i, row in enumerate(rows):
        path = destination / row["cache"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            with np.load(cache / row["cache"]) as sample:
                image = torch.from_numpy(sample["image"].copy()).float()[None, None] / 255
                with torch.inference_mode(): hint = teacher(image)[0].numpy().astype(np.float16)
                if not np.isfinite(hint).all(): raise ValueError("Nonfinite cached feature hint")
                np.savez(path, hint=hint)
        if (i + 1) % 50 == 0 or i + 1 == len(rows):
            print(f"HINT_CACHE {i+1}/{len(rows)} seconds={time.perf_counter()-begin:.1f}", flush=True)
