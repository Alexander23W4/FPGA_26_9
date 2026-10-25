"""Quality baseline: quantize all original weights, preserve the full network.

Evaluates INT8 weights after FP32 dequantization. This is NOT integer activation
inference and does not modify the current FPGA model or claim a speed increase.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from models import ROOT, Teacher
from train import CachedFrames, confusion, metrics
from export_decoder import edges
from torch.nn import functional as F


@torch.inference_mode()
def run(args):
    torch.set_num_threads(args.threads)
    original = Teacher().eval()
    quant = copy.deepcopy(original)
    blob, records = bytearray(), []
    for i, op in enumerate(original.graph["ops"]):
        if op["kind"] not in (0, 1): continue
        w = getattr(original, f"weight_{i}").numpy().astype("<f4")
        b = getattr(original, f"bias_{i}").numpy().astype("<f4")
        maximum = np.abs(w).reshape(len(w), -1).max(1)
        scale = np.where(maximum > 0, maximum / 127, 1).astype("<f4")
        ints = np.rint(w / scale[:, None, None, None]).clip(-127, 127).astype("i1")
        wo = len(blob); blob.extend(ints.tobytes())
        while len(blob) % 4: blob.append(0)
        so = len(blob); blob.extend(scale.tobytes())
        bo = len(blob); blob.extend(b.tobytes())
        getattr(quant, f"weight_{i}").copy_(torch.from_numpy(ints.astype(np.float32) * scale[:, None, None, None]))
        records.append({"operator": i, "name": op["name"], "shape_oihw": list(w.shape),
                        "weight_offset": wo, "scale_offset": so, "bias_offset": bo})
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "weights_int8.bin").write_bytes(blob)
    manifest = {"format": "full_original_model_per_channel_INT8_storage_v1", "network_pruned": False,
                "teacher_sha256": original.graph["weights_sha256"], "layers": records,
                "weight_bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest(),
                "activation_integer_inference_validated": False, "current_fpga_loader_compatible": False,
                "macs_per_frame": original.graph["macs_per_frame"]}
    (args.out / "model.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    samples = CachedFrames(args.cache, "test")
    matrix = torch.zeros(5, 5, dtype=torch.long)
    sums = torch.zeros(4, 4, dtype=torch.double)
    count = 0
    for image, _, _ in torch.utils.data.DataLoader(samples, batch_size=2):
        ref, pred = original(image).argmax(1), quant(image).argmax(1)
        matrix += confusion(pred, ref)
        a, b = edges(pred), edges(ref)
        sums[0] += (a * F.max_pool2d(b, 3, 1, 1)).sum((0, 2, 3)).double()
        sums[1] += (b * F.max_pool2d(a, 3, 1, 1)).sum((0, 2, 3)).double()
        sums[2] += a.sum((0, 2, 3)).double()
        sums[3] += b.sum((0, 2, 3)).double()
        count += len(image)
        if count % 16 == 0: print(f"ORIGINAL_INT8_CHECK {count}/{len(samples)}", flush=True)
    precision, recall = sums[0] / sums[2].clamp_min(1), sums[1] / sums[3].clamp_min(1)
    f1 = 2 * precision * recall / (precision + recall).clamp_min(1e-12)
    report = metrics(matrix)
    report.update({"boundary_f1_1px_per_class": f1.tolist(), "boundary_f1_1px_mean": float(f1.mean()),
                   "weight_bytes": len(blob), "weight_storage_reduction": 26457792 / len(blob),
                   "test_frames": count, "full_integer_inference": False, "fpga_model_changed": False,
                   "clinical_ground_truth_comparison": False, "macs_changed": False})
    (args.out / "verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("ORIGINAL_WEIGHT_INT8_VERIFIED", json.dumps(report), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cache", type=Path, default=ROOT / "build/unet_distill/cache_patient")
    p.add_argument("--out", type=Path, default=ROOT / "build/unet_distill/original_int8")
    p.add_argument("--threads", type=int, default=2)
    run(p.parse_args())
