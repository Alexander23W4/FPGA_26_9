#!/usr/bin/env python3
"""Batch-run the golden model over an official CAMUS split.

Examples (PowerShell):
    python run_camus.py --split testing --limit 8
    python run_camus.py --split validation --out-csv validation.csv

The script never trains or tunes anything, so it is safe to use the official
testing split for a one-time report.
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import golden_metrics as gm


SPLIT_FILES = {
    "training": "subgroup_training.txt",
    "validation": "subgroup_validation.txt",
    "testing": "subgroup_testing.txt",
}

SUMMARY_FIELDS = (
    "edv_ml",
    "esv_ml",
    "ef_percent",
    "gls_percent",
    "long_axis_shortening_percent",
)


def mean(values: Sequence[float]) -> Optional[float]:
    return float(statistics.mean(values)) if values else None


def std(values: Sequence[float]) -> Optional[float]:
    return float(statistics.pstdev(values)) if len(values) > 1 else 0.0


def run_split(
    data_root: Path,
    split: str,
    view: str,
    limit: int,
    registration_frames: int,
    roi: int,
    search: int,
    subpixel: bool,
    out_csv: Path,
) -> Dict[str, object]:
    split_file = data_root.parent / "database_split" / SPLIT_FILES[split]
    names = gm.official_split(split_file)
    if limit > 0:
        names = names[:limit]

    rows: List[Dict[str, object]] = []
    for index, name in enumerate(names, 1):
        patient_dir = data_root / name
        row: Dict[str, object] = {"patient": name, "status": "ok", "error": ""}
        try:
            r = gm.compute_patient(
                patient_dir,
                view=view,
                registration_frames=registration_frames,
                roi=roi,
                search=search,
                subpixel=subpixel,
            )
            row.update(
                {
                    "frames": r["frames"],
                    "ed_frame": r["ed_frame"],
                    "es_frame": r["es_frame"],
                    "edv_ml": r["edv_ml"],
                    "esv_ml": r["esv_ml"],
                    "ef_percent": r["ef_percent"],
                    "gls_percent": r["gls_percent"],
                    "long_axis_shortening_percent": r["long_axis_shortening_percent"],
                    "spacing_x_mm": r["spacing_mm"][1],
                    "spacing_y_mm": r["spacing_mm"][0],
                }
            )
            regs = r["registration"]
            if regs:
                row["mean_abs_dx_px"] = mean([abs(float(v["dx"])) for v in regs])
                row["mean_abs_dy_px"] = mean([abs(float(v["dy"])) for v in regs])
                row["mean_sad"] = mean([float(v["sad"]) for v in regs])
            print(f"[{index:3d}/{len(names):3d}] {name}: EF={r['ef_percent']:.2f}% GLS={r['gls_percent']:.2f}%", file=sys.stderr)
        except Exception as exc:  # keep going so one bad patient does not hide the rest
            row["status"] = "error"
            row["error"] = f"{type(exc).__name__}: {exc}"
            print(f"[{index:3d}/{len(names):3d}] {name}: ERROR {row['error']}", file=sys.stderr)
        rows.append(row)

    fieldnames: List[str] = []
    for row in rows:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open("w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    ok_rows = [r for r in rows if r["status"] == "ok"]
    summary: Dict[str, object] = {
        "split": split,
        "view": view,
        "patients_requested": len(names),
        "patients_ok": len(ok_rows),
        "patients_failed": len(rows) - len(ok_rows),
        "csv": str(out_csv),
        "metrics": {},
    }
    for key in SUMMARY_FIELDS:
        values = [float(r[key]) for r in ok_rows if r.get(key) is not None]
        summary["metrics"][key] = {"mean": mean(values), "std": std(values), "n": len(values)}
    return summary


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path(r"C:\Users\13995\Desktop\fpga校赛\CAMUS_public\database_nifti"),
        help="CAMUS database_nifti directory",
    )
    parser.add_argument("--split", choices=tuple(SPLIT_FILES), default="testing")
    parser.add_argument("--view", choices=("2CH", "4CH"), default="4CH")
    parser.add_argument("--limit", type=int, default=8, help="0 means all patients in the split")
    parser.add_argument("--registration-frames", type=int, default=3)
    parser.add_argument("--roi", type=int, default=96)
    parser.add_argument("--search", type=int, default=8)
    parser.add_argument("--no-subpixel", action="store_true")
    parser.add_argument("--out-csv", type=Path, default=None)
    parser.add_argument("--summary-json", type=Path, default=None)
    args = parser.parse_args(argv)

    out_csv = args.out_csv or Path(f"camus_{args.split}_{args.view}_metrics.csv")
    result = run_split(
        data_root=args.data_root,
        split=args.split,
        view=args.view,
        limit=max(0, args.limit),
        registration_frames=args.registration_frames,
        roi=args.roi,
        search=args.search,
        subpixel=not args.no_subpixel,
        out_csv=out_csv,
    )
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.summary_json:
        args.summary_json.write_text(text, encoding="utf-8")
    print(text)
    return 0 if result["patients_ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
