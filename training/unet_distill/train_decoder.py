"""Accuracy-first distillation with the original trained encoder frozen."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import time

import numpy as np
import torch
from torch.nn import functional as F
from torch.utils.data import Dataset, DataLoader

from models import ROOT, Teacher
from decoder_student import DecoderStudent, cache_features, cache_hints, profile_decoder
from train import confusion, metrics, dice_loss


class FeatureDataset(Dataset):
    def __init__(self, cache, split, hints=False):
        self.samples = []
        self.hints = []
        self.histogram = torch.zeros(5)
        for row in json.loads((cache / "samples.json").read_text(encoding="utf-8")):
            if row["split"] != split: continue
            with np.load(cache / row["cache"]) as sample, np.load(cache / "encoder_features" / row["cache"]) as feats:
                scores = sample["logits"].copy()
                self.samples.append((tuple(torch.from_numpy(feats[f"f{j}"].copy()) for j in range(5)), torch.from_numpy(scores)))
                self.histogram += torch.from_numpy(np.bincount(scores.argmax(0).ravel(), minlength=5)).float()
            if hints:
                with np.load(cache / "teacher_last16" / row["cache"]) as item:
                    self.hints.append(torch.from_numpy(item["hint"].copy()))

    def __len__(self): return len(self.samples)

    def __getitem__(self, index):
        features, logits = self.samples[index]
        values = (tuple(f.float() for f in features), logits.float())
        return values + (self.hints[index].float(),) if self.hints else values


@torch.inference_mode()
def evaluate_decoder(model, loader):
    model.eval()
    device = next(model.parameters()).device
    matrix = torch.zeros(5, 5, dtype=torch.long)
    for features, teacher in loader:
        features = tuple(f.to(device) for f in features)
        matrix += confusion(model.decode(features).argmax(1).cpu(), teacher.argmax(1))
    return metrics(matrix)


def save(path, payload):
    temporary = path.with_suffix(".tmp")
    torch.save(payload, temporary)
    temporary.replace(path)


def train(args):
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    random.seed(args.seed)
    np.random.seed(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)
    if (args.out / "best.pt").exists() and not args.resume:
        raise ValueError("Choose a new output or --resume")
    cache_features(args.cache, args.threads)
    if args.hint_weight:
        if args.detail_width != 16: raise ValueError("Feature hints need --detail-width 16")
        cache_hints(args.cache, args.threads)
    model = DecoderStudent(args.base, detail_width=args.detail_width)
    model.initialize_from_teacher()
    if args.initialize:
        source = torch.load(args.initialize, map_location="cpu", weights_only=False)["state_dict"]
        target = model.state_dict()
        matched = {key: value for key, value in source.items() if key in target and target[key].shape == value.shape}
        model.load_state_dict(matched, strict=False)
        print(f"WARM_START {len(matched)}/{len(target)} tensors; different shapes retain teacher initialization", flush=True)
    if args.hint_weight:
        teacher = Teacher()
        index = next(i for i, o in enumerate(teacher.graph["ops"]) if o["name"] == "segmentation_head")
        with torch.no_grad():
            model.head.weight.copy_(getattr(teacher, f"weight_{index}"))
            model.head.bias.copy_(getattr(teacher, f"bias_{index}"))
        model.head.requires_grad_(False)
    datasets = {s: FeatureDataset(args.cache, s, hints=args.hint_weight > 0 and s == "train") for s in ("train", "validation", "test")}
    loaders = {s: DataLoader(ds, args.batch_size, shuffle=s == "train", num_workers=0) for s, ds in datasets.items()}
    weights = (datasets["train"].histogram.sum() / datasets["train"].histogram.clamp_min(1)).sqrt().clamp_max(12)
    weights /= weights.mean()
    details = profile_decoder(model)
    device = torch.device(args.device)
    if device.type == "cuda" and not torch.cuda.is_available(): raise ValueError("CUDA is not available")
    model.to(device)
    weights = weights.to(device)
    details.update({"seed": args.seed, "torch": torch.__version__, "device": str(device), "feature_cache": "FP16; FP32 decoder training",
                    "loss": "class-balanced CE + foreground Dice + KL(T=2)*0.5; optional boundary CE and teacher last-feature MSE",
                    "hint_weight": args.hint_weight, "boundary_weight": args.boundary_weight,
                    "sample_counts": {s: len(ds) for s, ds in datasets.items()},
                    "patients": json.loads((args.cache / "patients.json").read_text(encoding="utf-8")),
                    "teacher": json.loads((args.cache / "configuration.json").read_text(encoding="utf-8")),
                    "decoder_code_sha256": hashlib.sha256((Path(__file__).parent / "decoder_student.py").read_bytes()).hexdigest()})
    (args.out / "configuration.json").write_text(json.dumps(details, indent=2), encoding="utf-8")
    print("DECODER_CONFIGURATION", json.dumps(details), flush=True)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-5)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.epochs, eta_min=args.lr * .05)
    history, best, first, best_epoch = [], -1., 0, -1
    if args.resume:
        checkpoint = torch.load(args.out / "last.pt", map_location="cpu", weights_only=False)
        model.load_state_dict(checkpoint["state_dict"])
        optimizer.load_state_dict(checkpoint["optimizer"])
        for group in optimizer.param_groups: group["lr"] = args.lr
        first = checkpoint["epoch"] + 1
        previous = torch.load(args.out / "best.pt", map_location="cpu", weights_only=False)
        best, best_epoch = previous["score"], previous["epoch"]
        history = json.loads((args.out / "history.json").read_text(encoding="utf-8"))
    begin = time.perf_counter()
    for epoch in range(first, first + args.epochs):
        model.train()
        total = 0.
        for batch in loaders["train"]:
            features, teacher = batch[:2]
            optimizer.zero_grad(set_to_none=True)
            # Perturb cached features slightly; don't pair a transformed image
            # with untransformed encoder features or flip chamber laterality.
            features = tuple(f.to(device) for f in features)
            features = tuple(f + torch.randn_like(f) * .002 for f in features)
            teacher = teacher.to(device)
            decoded = model.decode_features(features)
            student = model.head(decoded)
            target = teacher.argmax(1)
            pixel_weight = 1 + 4. * (target != 0).float()
            kl = F.kl_div((student / 2).log_softmax(1), (teacher / 2).softmax(1), reduction="none").sum(1)
            kd = (kl * pixel_weight).sum() / pixel_weight.sum() * 4
            if args.boundary_weight:
                padded = F.pad(target, (1, 1, 1, 1))
                edge = ((padded[:, :-2, 1:-1] != target) | (padded[:, 2:, 1:-1] != target) |
                        (padded[:, 1:-1, :-2] != target) | (padded[:, 1:-1, 2:] != target)) & (target > 0)
                corridor = F.max_pool2d(edge[:, None].float(), 3, 1, 1)[:, 0]
                pixel = 1 + args.boundary_weight * corridor
                ce = (F.cross_entropy(student, target, weight=weights, reduction="none") * pixel).sum() / (weights[target] * pixel).sum()
            else:
                ce = F.cross_entropy(student, target, weight=weights)
            loss = ce + dice_loss(student, target) + .5 * kd
            if args.hint_weight:
                hint = batch[2].to(device)
                scale = hint.square().mean((2, 3), keepdim=True).sqrt().clamp_min(.5)
                loss = loss + args.hint_weight * ((decoded - hint) / scale).square().mean()
            if not torch.isfinite(loss): raise ValueError("Nonfinite decoder loss")
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 5)
            optimizer.step()
            total += float(loss.detach())
        scheduler.step()
        validation = evaluate_decoder(model, loaders["validation"])
        score = validation["mean_foreground_dice"]
        history.append({"epoch": epoch, "loss": total / len(loaders["train"]), "validation": validation,
                        "seconds": time.perf_counter() - begin})
        payload = {"architecture": "frozen_original_encoder_narrow_decoder_v1", "base": args.base, "detail_width": args.detail_width,
                   "state_dict": model.state_dict(), "optimizer": optimizer.state_dict(), "epoch": epoch,
                   "score": score, "configuration": details}
        save(args.out / "last.pt", payload)
        if score > best:
            best, best_epoch = score, epoch
            save(args.out / "best.pt", payload)
        (args.out / "history.json").write_text(json.dumps(history, indent=2), encoding="utf-8")
        print(f"DECODER_EPOCH {epoch+1}: loss={total/len(loaders['train']):.4f} val_fg_dice={score:.4f} "
              f"best={best:.4f} seconds={time.perf_counter()-begin:.1f}", flush=True)
        if (args.out / "STOP").exists() or (args.patience and epoch - best_epoch >= args.patience): break
    checkpoint = torch.load(args.out / "best.pt", map_location="cpu", weights_only=False)
    model.load_state_dict(checkpoint["state_dict"])
    report = {"status": "trained_candidate", "profile": details, "best_epoch": checkpoint["epoch"],
              "validation_teacher": evaluate_decoder(model, loaders["validation"]),
              "test_teacher": evaluate_decoder(model, loaders["test"]),
              "fpga_replaced": False, "clinical_accuracy_verified": False,
              "feature_cache_used": True, "full_input_verification": "requires export step"}
    (args.out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("DECODER_DISTILLATION_COMPLETE", json.dumps(report), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cache", type=Path, default=ROOT / "build/unet_distill/cache_patient")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--base", type=int, default=32)
    p.add_argument("--detail-width", type=int, default=8, choices=(8, 16), help="Keep 16 full-resolution channels to preserve contour detail")
    p.add_argument("--initialize", type=Path, help="Warm-start matching tensors from another decoder student")
    p.add_argument("--hint-weight", type=float, default=0, help="Distill 16-channel final teacher features; freezes the original segmentation head")
    p.add_argument("--boundary-weight", type=float, default=0, help="Extra CE weight near teacher contours")
    p.add_argument("--epochs", type=int, default=40)
    p.add_argument("--threads", type=int, default=2)
    p.add_argument("--device", default="cpu")
    p.add_argument("--batch-size", type=int, default=8)
    p.add_argument("--seed", type=int, default=2609)
    p.add_argument("--lr", type=float, default=.001)
    p.add_argument("--patience", type=int, default=12)
    p.add_argument("--resume", action="store_true")
    args = p.parse_args()
    if min(args.epochs, args.batch_size, args.threads) < 1 or args.lr <= 0:
        p.error("epochs, batch size, threads and LR must be positive")
    if min(args.hint_weight, args.boundary_weight, args.patience) < 0:
        p.error("loss weights and patience must be nonnegative")
    train(args)
