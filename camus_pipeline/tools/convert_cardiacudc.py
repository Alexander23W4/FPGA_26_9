#!/usr/bin/env python3
"""Convert CardiacUDC NIfTI cine loops into GUI-ready 256x256 BIN frames."""

import argparse
import csv
import re
from pathlib import Path

from convert_camus import fit, read_nii


FRAME_BYTES = 256 * 256


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return value.strip("._") or "sequence"


def convert_sequence(image_path: Path, output_dir: Path, overwrite: bool):
    data, meta = read_nii(image_path)
    if data.ndim != 3:
        raise ValueError(f"expected a 3D cine volume [x,y,frame], got {data.shape}")
    x_size, y_size, frame_count = map(int, data.shape)
    if frame_count <= 0:
        raise ValueError("NIfTI contains no frames")

    output_dir.mkdir(parents=True, exist_ok=True)
    for frame_index in range(frame_count):
        # NIfTI stores spatial axes as x,y; raster images are row(y),column(x).
        # Display coordinates use x to the right and y downward. The source
        # cine volumes store x,y axes with the ultrasound sector apex at y-max.
        frame = data[:, :, frame_index].T[::-1, :]
        if frame.dtype.name != "uint8":
            raise ValueError(f"expected 8-bit source pixels, got {frame.dtype}")
        square, transform = fit(frame, (256, 256), nearest=False)
        payload = square.tobytes(order="C")
        if len(payload) != FRAME_BYTES:
            raise ValueError(f"frame {frame_index} produced {len(payload)} bytes")
        target = output_dir / f"{frame_index:06d}.bin"
        if target.exists() and not overwrite:
            raise FileExistsError(f"{target} already exists (pass --overwrite to replace it)")
        target.write_bytes(payload)

    label_path = image_path.with_name(image_path.name.replace("_image.nii.gz", "_label.nii.gz"))
    return {
        "site": image_path.parent.name,
        "sequence": image_path.name.removesuffix("_image.nii.gz"),
        "source": str(image_path),
        "source_shape_xy_frames": f"{x_size}x{y_size}x{frame_count}",
        "source_dtype": meta["dtype"],
        "frame_count": frame_count,
        "label_available": label_path.is_file(),
        "gui_bin_folder": str(output_dir),
        "bin_bytes_per_frame": FRAME_BYTES,
        "resize_method": transform["method"],
        "resized_size": "x".join(map(str, transform["resized_size"])),
        "padding_xy": "x".join(map(str, transform["padding_xy"])),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True,
                        help="cardiacUDC_dataset root")
    parser.add_argument("--output", type=Path, required=True,
                        help="new output root; source files are not modified")
    parser.add_argument("--limit", type=int, default=0,
                        help="convert only the first N sequences (for a quick check)")
    parser.add_argument("--overwrite", action="store_true",
                        help="replace BIN frames that already exist")
    args = parser.parse_args()

    source_root = args.input.resolve()
    output_root = args.output.resolve()
    if not source_root.is_dir():
        parser.error(f"input directory does not exist: {source_root}")
    if source_root == output_root or source_root in output_root.parents:
        parser.error("output must be separate from the source dataset")

    sources = sorted(p for p in source_root.rglob("*_image.nii.gz") if p.is_file())
    if args.limit:
        sources = sources[:args.limit]
    if not sources:
        parser.error(f"no *_image.nii.gz files found under {source_root}")

    rows = []
    for index, image_path in enumerate(sources, 1):
        site = safe_name(image_path.parent.name)
        sequence = safe_name(image_path.name.removesuffix("_image.nii.gz"))
        output_dir = output_root / "sequences" / site / sequence
        try:
            row = convert_sequence(image_path, output_dir, args.overwrite)
            row["status"] = "converted"
        except Exception as exc:
            row = {"site": site, "sequence": sequence, "source": str(image_path),
                   "status": "error", "error": repr(exc)}
        rows.append(row)
        print(f"[{index}/{len(sources)}] {site}/{sequence}: {row['status']}"
              + (f" ({row.get('frame_count', 0)} frames)" if row["status"] == "converted" else ""),
              flush=True)

    output_root.mkdir(parents=True, exist_ok=True)
    manifest = output_root / "manifest.csv"
    fields = ["status", "site", "sequence", "source", "source_shape_xy_frames",
              "source_dtype", "frame_count", "label_available", "gui_bin_folder",
              "bin_bytes_per_frame", "resize_method", "resized_size", "padding_xy", "error"]
    with manifest.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    converted = sum(row["status"] == "converted" for row in rows)
    failed = len(rows) - converted
    frame_count = sum(int(row.get("frame_count", 0)) for row in rows)
    print(f"Output: {output_root}")
    print(f"Sequences converted: {converted}; failed: {failed}; frames: {frame_count}")
    print(f"Manifest: {manifest}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
