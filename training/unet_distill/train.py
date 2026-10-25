"""Train a small student with teacher KL, balanced pseudo-label CE and Dice."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import random
import time

import numpy as np
import torch
from torch.nn import functional as F
from torch.utils.data import DataLoader, Dataset

from models import ROOT, Student, profile


class CachedFrames(Dataset):
    def __init__(self, cache, split, crop=0):
        self.crop = crop
        self.samples = []
        self.foregrounds = []
        self.histogram = torch.zeros(5)
        for row in json.loads((cache / "samples.json").read_text(encoding="utf-8")):
            if row["split"] == split:
                with np.load(cache / row["cache"]) as sample:
                    self.samples.append(tuple(torch.from_numpy(sample[key].copy()) for key in ("image", "logits", "raw_gt")))
                    hard = sample["logits"].argmax(0)
                    self.foregrounds.append([np.argwhere(hard == category) for category in range(1, 5) if np.any(hard == category)])
                    self.histogram += torch.from_numpy(np.bincount(hard.ravel(), minlength=5)).float()
        if not self.samples:
            raise ValueError(f"Empty {split} partition")

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, index):
        image, scores, gt = self.samples[index]
        if self.crop:
            side = self.crop
            present = self.foregrounds[index]
            if present and random.random() < .8:
                positions = present[random.randrange(len(present))]
                cy, cx = positions[random.randrange(len(positions))].tolist()
                cy += random.randint(-side // 4, side // 4)
                cx += random.randint(-side // 4, side // 4)
                y, x = max(0, min(256 - side, cy - side // 2)), max(0, min(256 - side, cx - side // 2))
            else:
                y, x = random.randrange(257 - side), random.randrange(257 - side)
            image, scores, gt = image[y:y+side, x:x+side], scores[:, y:y+side, x:x+side], gt[y:y+side, x:x+side]
        return image.float().unsqueeze(0) / 255, scores.float(), gt.long()


def confusion(predicted, expected):
    valid = (expected >= 0) & (expected < 5)
    return torch.bincount((expected[valid] * 5 + predicted[valid]).flatten(), minlength=25).reshape(5, 5).cpu()


def metrics(matrix):
    matrix = matrix.double()
    den = matrix.sum(0) + matrix.sum(1)
    dice = 2 * matrix.diag() / den.clamp_min(1)
    present = den[1:] > 0
    return {"mean_foreground_dice": float(dice[1:][present].mean()) if present.any() else None,
            "per_class_dice": dice.tolist(), "present_classes": (den > 0).tolist(),
            "pixel_agreement": float(matrix.diag().sum() / matrix.sum().clamp_min(1)),
            "confusion_expected_rows_predicted_columns": matrix.long().tolist()}


def dice_loss(scores, labels, ignore=255):
    valid = labels != ignore
    targets = F.one_hot(labels.clamp(0, 4), 5).permute(0, 3, 1, 2).float()
    mask = valid[:, None]
    probs = scores.softmax(1) * mask
    targets = targets * mask
    dims = (0, 2, 3)
    intersect = (probs * targets).sum(dims)
    sums = probs.sum(dims) + targets.sum(dims)
    return 1 - ((2 * intersect[1:] + 1) / (sums[1:] + 1)).mean()


def augmentation(image, teacher, labels):
    # Spatial transforms must be shared by both targets, not just the image.
    if torch.rand(()) < .5:
        image, teacher, labels = image.flip(-1), teacher.flip(-1), labels.flip(-1)
    dy, dx = random.randint(-8, 8), random.randint(-8, 8)
    image = torch.roll(image, (dy, dx), (-2, -1))
    teacher = torch.roll(teacher, (dy, dx), (-2, -1))
    labels = torch.roll(labels, (dy, dx), (-2, -1))
    valid = torch.ones_like(labels, dtype=torch.bool)
    if dy > 0: valid[:, :dy] = False
    if dy < 0: valid[:, dy:] = False
    if dx > 0: valid[:, :, :dx] = False
    if dx < 0: valid[:, :, dx:] = False
    image = image * valid[:, None]
    fill = teacher.new_full((1, 5, 1, 1), -6)
    fill[:, 0] = 6
    teacher = torch.where(valid[:, None], teacher, fill)
    labels = torch.where(valid, labels, 255)
    image = (image * random.uniform(.9, 1.1) + torch.randn_like(image) * .015).clamp(0, 1)
    return image, teacher, labels


@torch.inference_mode()
def evaluate(model, loader, device, label_map=None):
    model.eval()
    teacher_matrix = torch.zeros(5, 5, dtype=torch.long)
    label_matrix = torch.zeros_like(teacher_matrix)
    for image, teacher, labels in loader:
        predicted = model(image.to(device)).argmax(1).cpu()
        teacher_matrix += confusion(predicted, teacher.argmax(1))
        if label_map is not None:
            labels = torch.where(labels < 5, label_map[labels.clamp(0, 4)], 255)
            label_matrix += confusion(predicted, labels)
    return {"teacher": metrics(teacher_matrix),
            "annotations": metrics(label_matrix) if label_map is not None else None}


def train(args):
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    random.seed(args.seed)
    np.random.seed(args.seed)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "best.pt").exists() and not args.resume:
        raise ValueError("Output contains a checkpoint; use --resume or a new --out")
    device = torch.device(args.device)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise ValueError("CUDA is not available")
    label_map = None
    if args.label_map:
        mapping = list(map(int, args.label_map.split(",")))
        if sorted(mapping) != list(range(5)) or mapping[0] != 0:
            raise ValueError("--label-map must map raw IDs 0..4 to teacher IDs, with background 0")
        label_map = torch.tensor(mapping, dtype=torch.long)
    datasets = {s: CachedFrames(args.cache, s, crop=args.crop if s == "train" else 0) for s in ("train", "validation", "test")}
    loaders = {s: DataLoader(ds, args.batch_size, shuffle=s == "train", num_workers=0)
               for s, ds in datasets.items()}
    model = Student(args.width).to(device)
    details = profile(model)
    details.update({"teacher_macs": 3373326336, "mac_reduction": 3373326336 / details["macs_per_frame"],
                    "torch": torch.__version__, "device": str(device), "seed": args.seed,
                    "epochs_requested": args.epochs, "sample_counts": {s: len(d) for s, d in datasets.items()},
                    "patient_partitions": json.loads((args.cache / "patients.json").read_text(encoding="utf-8")),
                    "cache_configuration": json.loads((args.cache / "configuration.json").read_text(encoding="utf-8")),
                    "label_map_raw_to_teacher": None if label_map is None else label_map.tolist(),
                    "loss_recipe": "sqrt-frequency-balanced CE + foreground Dice + KL(T=2)*0.5; foreground patches 80%",
                    "training_crop": args.crop,
                    "models_source_sha256": hashlib.sha256((Path(__file__).parent / "models.py").read_bytes()).hexdigest()})
    (out / "configuration.json").write_text(json.dumps(details, indent=2), encoding="utf-8")
    print("TRAIN_CONFIGURATION", json.dumps(details), flush=True)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.epochs, eta_min=args.lr * .03)
    history, best, start_epoch, best_epoch = [], -1., 0, -1
    if args.resume:
        state = torch.load(out / "last.pt", map_location=device, weights_only=False)
        model.load_state_dict(state["state_dict"])
        optimizer.load_state_dict(state["optimizer"])
        # A longer resumed run gets a fresh cosine schedule, with the requested
        # new LR; do not silently restore an already exhausted schedule.
        for group in optimizer.param_groups: group["lr"] = args.lr
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.epochs, eta_min=args.lr * .03)
        history = json.loads((out / "history.json").read_text(encoding="utf-8"))
        previous = torch.load(out / "best.pt", map_location="cpu", weights_only=False)
        best, best_epoch, start_epoch = previous["score"], previous["epoch"], state["epoch"] + 1
    frequencies = datasets["train"].histogram
    # Foreground-centered patches fix the 97% background imbalance without
    # making the model label most background pixels as a chamber.
    class_weights = (frequencies.sum() / frequencies.clamp_min(1)).sqrt().clamp_max(12)
    class_weights /= class_weights.mean()
    class_weights = class_weights.to(device)
    begin = time.perf_counter()
    for epoch in range(start_epoch, start_epoch + args.epochs):
        model.train()
        total, batches = 0., 0
        for image, teacher, gt in loaders["train"]:
            image, teacher, gt = augmentation(image, teacher, gt)
            image, teacher, gt = image.to(device), teacher.to(device), gt.to(device)
            optimizer.zero_grad(set_to_none=True)
            student = model(image)
            hard = teacher.argmax(1)
            temperature = 2.
            soft = (teacher / temperature).softmax(1)
            weight = 1. + 4. * (hard != 0).float()
            divergence = F.kl_div((student / temperature).log_softmax(1), soft, reduction="none").sum(1)
            kd = (divergence * weight).sum() / weight.sum() * temperature ** 2
            loss = .5 * kd + F.cross_entropy(student, hard, weight=class_weights) + dice_loss(student, hard)
            if label_map is not None and (gt < 5).any():
                table = label_map.to(device)
                mapped = torch.where(gt < 5, table[gt.clamp(0, 4)], 255)
                loss = loss + F.cross_entropy(student, mapped, ignore_index=255) + dice_loss(student, mapped)
            if not torch.isfinite(loss):
                raise ValueError("Nonfinite training loss")
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5.)
            optimizer.step()
            total += float(loss.detach())
            batches += 1
        scheduler.step()
        validation = evaluate(model, loaders["validation"], device, label_map)
        # Choose on independent validation patients. Test data is used only at
        # the end; no test loss or score participates in checkpoint selection.
        score = validation["teacher"]["mean_foreground_dice"]
        record = {"epoch": epoch, "loss": total / batches, "validation": validation,
                  "loss_recipe": details["loss_recipe"],
                  "seconds": time.perf_counter() - begin}
        history.append(record)
        payload = {"architecture": "tiny_depthwise_unet_v1", "width": args.width,
                   "state_dict": model.state_dict(), "optimizer": optimizer.state_dict(),
                   "epoch": epoch, "score": score, "configuration": details}
        torch.save(payload, out / "last.pt")
        if score > best:
            best, best_epoch = score, epoch
            torch.save(payload, out / "best.pt")
        (out / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
        print(f"EPOCH {epoch + 1}: loss={total/batches:.4f} val_teacher_fg_dice={score:.4f} "
              f"best={best:.4f} seconds={time.perf_counter()-begin:.1f}", flush=True)
        if args.patience and epoch - best_epoch >= args.patience:
            break
        if (out / "STOP").exists():
            print("STOP_REQUESTED: finishing with best validation checkpoint", flush=True)
            break
    state = torch.load(out / "best.pt", map_location=device, weights_only=False)
    model.load_state_dict(state["state_dict"])
    report = {"status": "trained_candidate", "profile": details, "best_epoch": state["epoch"],
              "validation": evaluate(model, loaders["validation"], device, label_map),
              "test": evaluate(model, loaders["test"], device, label_map),
              "seconds_this_run": time.perf_counter() - begin,
              "claims": {"fpga_replaced": False, "clinical_accuracy_verified": False,
                         "independent_of_teacher_training_set": "unknown; original training manifest unavailable"}}
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("DISTILLATION_COMPLETE", json.dumps(report), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cache", type=Path, default=ROOT / "build/unet_distill/cache_patient")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--width", type=int, default=4)
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--patience", type=int, default=20)
    p.add_argument("--batch-size", type=int, default=8)
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("--crop", type=int, default=128, help="Training patch size; 0 uses complete frames. Evaluation is always 256x256")
    p.add_argument("--device", default="cpu")
    p.add_argument("--lr", type=float, default=.003)
    p.add_argument("--seed", type=int, default=2609)
    p.add_argument("--label-map", help="Explicit raw-to-teacher ID permutation, e.g. 0,3,1,2,4; default: teacher targets only")
    p.add_argument("--resume", action="store_true")
    args = p.parse_args()
    if min(args.epochs, args.batch_size, args.threads) < 1 or args.lr <= 0:
        p.error("epochs, batch size, threads and LR must be positive")
    if args.crop and (args.crop < 32 or args.crop > 256 or args.crop % 16):
        p.error("crop must be 0 or a multiple of 16 in [32,256]")
    train(args)
