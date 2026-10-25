"""Frozen original graph and small, synthesizable depthwise U-Net students."""
import json
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parents[2]


class Teacher(nn.Module):
    """Execute the checked, folded original model without downloading any weights."""
    def __init__(self, directory=ROOT / "build/unet/model", encoder_only=False, last_feature=False):
        super().__init__()
        directory = Path(directory)
        self.graph = json.loads((directory / "model.json").read_text(encoding="utf-8"))
        self.encoder_only = encoder_only
        self.last_feature = last_feature
        decoder_ops = [o for o in self.graph["ops"] if o["name"].endswith("upsample_cat")]
        self.feature_ids = [decoder_ops[0]["src"]] + [o["skip"] for o in decoder_ops if o["skip"] >= 0]
        blob = np.fromfile(directory / "weights.bin", dtype="<f4")
        import hashlib
        if hashlib.sha256(blob.tobytes()).hexdigest() != self.graph["weights_sha256"]:
            raise ValueError("Teacher weights do not match the exported graph")
        lanes = self.graph["lanes"]
        self.references = [0] * len(self.graph["tensors"])
        for index, op in enumerate(self.graph["ops"]):
            for key in ("src", "skip"):
                if op[key] >= 0:
                    self.references[op[key]] += 1
            if op["kind"] not in (0, 1):
                continue
            if encoder_only and (op["name"].startswith("decoder.") or op["name"] == "segmentation_head"):
                continue
            co, ci, k = op["cout"], op["cin"], op["kernel"]
            red = 1 if op["kind"] == 1 else ci
            padded = ((co + lanes - 1) // lanes) * lanes
            start = op["weights"]
            w = blob[start:start + padded * k * k * red]
            w = w.reshape(-1, k, k, red, lanes).transpose(0, 4, 3, 1, 2)
            w = w.reshape(padded, red, k, k)[:co].copy()
            self.register_buffer(f"weight_{index}", torch.from_numpy(w))
            self.register_buffer(f"bias_{index}", torch.from_numpy(blob[op["bias"]:op["bias"] + co].copy()))

    def forward(self, image):
        values = {0: image}
        refs = self.references.copy()
        for index, op in enumerate(self.graph["ops"]):
            if self.encoder_only and op["name"].startswith("decoder."):
                return tuple(values[tid] for tid in self.feature_ids)
            if self.last_feature and op["name"] == "segmentation_head":
                return values[op["src"]]
            x = values[op["src"]]
            if op["kind"] in (0, 1):
                x = F.conv2d(x, getattr(self, f"weight_{index}"), getattr(self, f"bias_{index}"),
                             stride=op["stride"], padding=op["kernel"] // 2,
                             groups=op["cin"] if op["kind"] == 1 else 1)
                if op["activation"]:
                    x = x.clamp_min(0)
                if op["activation"] == 2:
                    x = x.clamp_max(6)
            elif op["kind"] == 2:
                x = x + values[op["skip"]]
            else:
                x = F.interpolate(x, scale_factor=2, mode="nearest")
                if op["skip"] >= 0:
                    x = torch.cat((x, values[op["skip"]]), dim=1)
            values[op["dst"]] = x
            for key in ("src", "skip"):
                tid = op[key]
                if tid >= 0:
                    refs[tid] -= 1
                    if not refs[tid]:
                        del values[tid]
        return values[self.graph["logits"]]


def conv_norm(ci, co, kernel=1, stride=1, groups=1):
    return nn.Sequential(nn.Conv2d(ci, co, kernel, stride, kernel // 2, groups=groups, bias=False),
                         nn.BatchNorm2d(co), nn.ReLU6(inplace=False))


class Separable(nn.Sequential):
    def __init__(self, ci, co, stride=1):
        super().__init__(conv_norm(ci, ci, 3, stride, ci), conv_norm(ci, co))


class Decoder(nn.Module):
    def __init__(self, ci, skip, co):
        super().__init__()
        self.layers = nn.Sequential(Separable(ci + skip, co), Separable(co, co))

    def forward(self, x, skip):
        return self.layers(torch.cat((F.interpolate(x, scale_factor=2, mode="nearest"), skip), dim=1))


class Student(nn.Module):
    """Four downsamplings; 256x256 output, five original class IDs."""
    def __init__(self, width=8):
        super().__init__()
        if width not in (2, 4, 8, 12, 16):
            raise ValueError("Use width 2, 4, 8, 12 or 16")
        self.width = width
        self.stem = nn.Sequential(conv_norm(1, width, 3, 2), Separable(width, width))
        self.enc2 = nn.Sequential(Separable(width, width * 2, 2), Separable(width * 2, width * 2))
        self.enc3 = nn.Sequential(Separable(width * 2, width * 4, 2), Separable(width * 4, width * 4))
        self.enc4 = nn.Sequential(Separable(width * 4, width * 8, 2), Separable(width * 8, width * 8))
        self.dec3 = Decoder(width * 8, width * 4, width * 4)
        self.dec2 = Decoder(width * 4, width * 2, width * 2)
        self.dec1 = Decoder(width * 2, width, width)
        self.full = Separable(width + 1, width)
        self.head = nn.Conv2d(width, 5, 1)

    def forward(self, image):
        e1 = self.stem(image)
        e2 = self.enc2(e1)
        e3 = self.enc3(e2)
        x = self.enc4(e3)
        x = self.dec3(x, e3)
        x = self.dec2(x, e2)
        x = self.dec1(x, e1)
        x = F.interpolate(x, scale_factor=2, mode="nearest")
        return self.head(self.full(torch.cat((x, image), dim=1)))


def profile(model):
    macs = 0
    max_features = 0
    def count(layer, inputs, output):
        nonlocal macs, max_features
        macs += output.numel() * (layer.in_channels // layer.groups) * layer.kernel_size[0] * layer.kernel_size[1]
        max_features = max(max_features, output.numel())
    handles = [layer.register_forward_hook(count) for layer in model.modules() if isinstance(layer, nn.Conv2d)]
    was_training = model.training
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 1, 256, 256, device=next(model.parameters()).device))
    for handle in handles:
        handle.remove()
    model.train(was_training)
    parameters = sum(p.numel() for p in model.parameters())
    return {"width": model.width, "parameters": parameters, "fp32_parameter_bytes": parameters * 4,
            "int8_parameter_bytes_estimate": parameters, "macs_per_frame": macs,
            "largest_conv_output_elements": max_features,
            "arithmetic_lower_bound_ms_at_16x80MHz": macs / (16 * 80_000_000) * 1000,
            "hardware_fps_measured": False}
