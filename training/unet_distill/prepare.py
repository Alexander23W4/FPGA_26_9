"""Cache paired inputs and original teacher logits; split by patient, never by frame."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import sys
import time

import numpy as np
import torch

from models import ROOT, Teacher
sys.path.insert(0, str(ROOT / "camus_pipeline/tools"))
from convert_camus import fit, read_nii


def json_write(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def patient_id(path):
    stem = path.name.removesuffix("_image.nii.gz")
    # Group the same patient across acquisition sites and views, including the
    # dense-label duplicate directory. This is deliberately conservative.
    match = re.match(r"^(patient|normal)[_-]?0*(\d+)", stem)
    if not match:
        raise ValueError(f"Unknown patient naming scheme: {path.name}")
    return f"{match[1]}-{int(match[2])}"


def prepare(args):
    torch.set_num_threads(args.threads)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    model_graph = json.loads((args.model / "model.json").read_text(encoding="utf-8"))
    configuration = {"source": str(args.source.resolve()), "seed": args.seed,
                     "teacher_sha256": model_graph["weights_sha256"], "frames_per_sequence": args.frames,
                     "limits": [args.train_patients, args.val_patients, args.test_patients],
                     "transform": "NIfTI xyframe -> transpose, y-flip, letterbox Lanczos 256; /255",
                     "grouping_version": "patient numeric ID across sites, views and hyphen spellings v2",
                     "target_classes": ["background", "LA_provisional", "RA_provisional", "LV_provisional", "RV_provisional"]}
    config_path = out / "configuration.json"
    if config_path.exists() and json.loads(config_path.read_text(encoding="utf-8")) != configuration:
        raise ValueError("Cache configuration differs; choose a new --out directory")
    json_write(config_path, configuration)
    groups = {}
    # Equal filenames at different sites are separate acquisitions. Dense
    # annotation copies remain in the SAME patient partition, never another.
    for path in sorted(args.source.rglob("*_image.nii.gz")):
        groups.setdefault(patient_id(path), []).append(path)
    if len(groups) < 10:
        raise ValueError("Too few patients for independent train/validation/test partitions")
    ids = sorted(groups)
    random.Random(args.seed).shuffle(ids)
    nv, nt = max(1, round(len(ids) * .15)), max(1, round(len(ids) * .15))
    partitions = {"validation": ids[:nv], "test": ids[nv:nv + nt], "train": ids[nv + nt:]}
    limits = {"train": args.train_patients, "validation": args.val_patients, "test": args.test_patients}
    partitions = {key: value[:limits[key]] if limits[key] else value for key, value in partitions.items()}
    json_write(out / "patients.json", partitions)
    teacher = Teacher(args.model).eval()
    rows = []
    contingency = np.zeros((5, 5), dtype=np.int64)
    start = time.perf_counter()
    for split in ("train", "validation", "test"):
        for patient in partitions[split]:
            for path in groups[patient]:
                images, _ = read_nii(path)
                label_path = path.with_name(path.name.replace("_image", "_label"))
                labels = read_nii(label_path)[0] if label_path.exists() else None
                if images.ndim != 3 or (labels is not None and images.shape != labels.shape):
                    raise ValueError(f"Bad cine/label shape: {path}")
                indices = np.unique(np.linspace(0, images.shape[-1] - 1,
                                               min(args.frames, images.shape[-1]), dtype=int))
                for index in indices:
                    name = f"{path.parent.name}_{path.name.removesuffix('_image.nii.gz')}_{index:04d}"
                    target = out / split / (name + ".npz")
                    target.parent.mkdir(exist_ok=True)
                    if not target.exists():
                        gray, _ = fit(images[:, :, index].T[::-1, :], (256, 256))
                        if gray.dtype != np.uint8:
                            raise ValueError("Input must be uint8; do not silently change normalization")
                        with torch.inference_mode():
                            scores = teacher(torch.from_numpy(gray.copy()).float()[None, None] / 255)[0].numpy()
                        if not np.isfinite(scores).all():
                            raise ValueError("Nonfinite teacher output")
                        gt = np.full((256, 256), 255, np.uint8)
                        if labels is not None:
                            raw = labels[:, :, index].T[::-1, :]
                            # Sparse annotations often encode unlabeled frames
                            # as all zero: never train them as empty hearts.
                            if np.any(raw > 0):
                                if not np.isin(raw, np.arange(5)).all():
                                    raise ValueError(f"Unknown raw label IDs in {path}")
                                gt, _ = fit(raw.astype(np.uint8), (256, 256), nearest=True)
                        np.savez(target, image=gray, logits=scores.astype(np.float16), raw_gt=gt)
                    with np.load(target) as cached:
                        has_gt = bool(np.any(cached["raw_gt"] != 255))
                        if split == "train" and has_gt:
                            a = cached["raw_gt"].astype(int)
                            b = cached["logits"].argmax(0).astype(int)
                            contingency += np.bincount((a * 5 + b).ravel(), minlength=25).reshape(5, 5)
                    rows.append({"split": split, "patient": patient, "source": str(path),
                                 "frame": int(index), "cache": str(target.relative_to(out)), "has_gt": has_gt})
                print(f"CACHE {split} {patient}: {len(rows)} frames, {time.perf_counter() - start:.1f}s", flush=True)
    json_write(out / "samples.json", rows)
    # This is a training-only label correspondence audit, not automatic
    # permission to reinterpret the anatomical chamber names.
    possibilities = []
    for perm in itertools.permutations(range(1, 5)):
        mapping = (0,) + perm
        dice = [2 * contingency[c, mapping[c]] / max(1, contingency[c].sum() + contingency[:, mapping[c]].sum())
                for c in range(1, 5)]
        possibilities.append((float(np.mean(dice)), mapping, dice))
    possibilities.sort(reverse=True)
    score, mapping, dice = possibilities[0]
    json_write(out / "label_audit.json", {"training_only": True, "raw_to_teacher_candidate": mapping,
               "per_class_dice": dice, "mean_foreground_dice": score,
               "second_best_score": possibilities[1][0], "confusion_raw_rows_teacher_columns": contingency.tolist(),
               "automatically_used_for_training": False})
    print("DATA_READY", json.dumps({s: sum(r["split"] == s for r in rows) for s in partitions}), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source", type=Path, default=Path("E:/cardiarc_extract/cardiacUDC_dataset"))
    p.add_argument("--model", type=Path, default=ROOT / "build/unet/model")
    p.add_argument("--out", type=Path, default=ROOT / "build/unet_distill/cache_patient")
    p.add_argument("--frames", type=int, default=8)
    p.add_argument("--train-patients", type=int, default=48)
    p.add_argument("--val-patients", type=int, default=12)
    p.add_argument("--test-patients", type=int, default=12)
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("--seed", type=int, default=2609)
    args = p.parse_args()
    if args.frames < 1 or min(args.train_patients, args.val_patients, args.test_patients) < 0:
        p.error("frames must be positive and patient limits nonnegative (0 means all)")
    prepare(args)
