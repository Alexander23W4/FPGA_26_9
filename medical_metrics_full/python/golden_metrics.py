#!/usr/bin/env python3
"""Golden model for ultrasound frame registration and cardiac metrics.

This module deliberately depends only on Python's standard library and NumPy.
It reads CAMUS NIfTI-1 files directly, so it can run on a bare Windows Python
installation without SimpleITK, nibabel, SciPy, or scikit-image.

Coordinate convention used by the registration functions:
    prev[y, x] ~= curr[y + dy, x + dx]
where (dx, dy) is the integer (or sub-pixel) translation of the current frame
relative to the previous frame.  A positive dx therefore means that the
current frame content has moved to the right.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import json
import math
import statistics
import struct
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np

DTYPES = {
    2: "u1",       # uint8
    4: "i2",       # int16
    8: "i4",       # int32
    16: "f4",      # float32
    64: "f8",      # float64
    256: "i1",     # int8
    512: "u2",     # uint16
    768: "u4",     # uint32
    1024: "i8",    # int64
    1280: "u8",    # uint64
}


def read_nii_gz(path: Path | str) -> Tuple[np.ndarray, Dict[str, object]]:
    """Read a gzip-compressed NIfTI-1 file without external dependencies.

    NIfTI stores the fastest-changing axis first (Fortran order).  Converting
    to ``order='F'`` makes the returned array index as [y, x, frame] for the
    CAMUS half-sequence files.
    """
    path = Path(path)
    with gzip.open(path, "rb") as fh:
        raw = fh.read()
    if len(raw) < 348:
        raise ValueError(f"not a NIfTI-1 file (too short): {path}")

    if struct.unpack("<i", raw[:4])[0] == 348:
        endian = "<"
    elif struct.unpack(">i", raw[:4])[0] == 348:
        endian = ">"
    else:
        raise ValueError(f"not a NIfTI-1 file: {path}")

    dim = struct.unpack(endian + "8h", raw[40:56])
    datatype = struct.unpack(endian + "h", raw[70:72])[0]
    pixdim = struct.unpack(endian + "8f", raw[76:108])
    data_offset = int(round(struct.unpack(endian + "f", raw[108:112])[0]))
    slope, inter = struct.unpack(endian + "2f", raw[112:120])

    ndim = int(dim[0])
    if ndim < 1 or ndim > 7:
        raise ValueError(f"invalid NIfTI dimensionality {ndim}: {path}")
    shape = tuple(int(v) for v in dim[1 : ndim + 1])
    code = DTYPES.get(int(datatype))
    if code is None:
        raise ValueError(f"unsupported NIfTI datatype {datatype}: {path}")

    count = int(np.prod(shape))
    dtype = np.dtype(endian + code)
    arr = np.frombuffer(raw, dtype=dtype, count=count, offset=data_offset)
    arr = arr.reshape(shape, order="F")
    if slope != 0 and (slope != 1 or inter != 0):
        arr = arr.astype(np.float32) * slope + inter

    return arr, {
        "spacing": [float(v) for v in pixdim[1 : ndim + 1]],
        "shape": list(shape),
        "datatype": int(datatype),
        "data_offset": data_offset,
    }


def write_nii_gz(path: Path | str, array: np.ndarray, spacing: Sequence[float] = (1.0, 1.0, 1.0)) -> None:
    """Write a minimal NIfTI-1 single-file .nii.gz (useful for tests/demos).

    Only the subset needed by this project is implemented.  It is not a
    general-purpose NIfTI writer.
    """
    path = Path(path)
    a = np.asarray(array)
    if a.ndim != 3:
        raise ValueError("write_nii_gz currently supports 3-D arrays only")
    if a.dtype == np.uint8:
        dt = 2
        code = "u1"
    elif a.dtype == np.float32:
        dt = 16
        code = "f4"
    elif a.dtype == np.int16:
        dt = 4
        code = "i2"
    else:
        raise ValueError("supported dtypes: uint8, int16, float32")

    header = bytearray(348)
    struct.pack_into("<i", header, 0, 348)
    struct.pack_into("<8h", header, 40, 3, *a.shape, 1, 1, 1, 1)
    struct.pack_into("<h", header, 70, dt)
    struct.pack_into("<8f", header, 76, 1.0, *[float(v) for v in spacing], 1.0, 1.0, 1.0, 1.0)
    struct.pack_into("<f", header, 108, 352.0)
    struct.pack_into("<2f", header, 112, 1.0, 0.0)
    header[344:348] = b"n+1\x00"
    payload = a.astype(np.dtype("<" + code), copy=False).tobytes(order="F")
    with gzip.open(path, "wb") as fh:
        fh.write(bytes(header))
        fh.write(b"\x00\x00\x00\x00")
        fh.write(payload)


def normalize_u8(image: np.ndarray, low_percentile: float = 1.0, high_percentile: float = 99.0) -> np.ndarray:
    """Robustly map an image to uint8 using percentile clipping."""
    x = np.asarray(image, dtype=np.float32)
    if x.size == 0:
        return np.zeros(x.shape, dtype=np.uint8)
    lo = float(np.percentile(x, low_percentile))
    hi = float(np.percentile(x, high_percentile))
    if not math.isfinite(lo) or not math.isfinite(hi) or hi <= lo:
        return np.zeros(x.shape, dtype=np.uint8)
    return np.clip(np.rint((x - lo) * 255.0 / (hi - lo)), 0, 255).astype(np.uint8)


def _bilinear_sample(image: np.ndarray, yy: np.ndarray, xx: np.ndarray) -> np.ndarray:
    """Bilinear sample an image at floating coordinates with zero border."""
    h, w = image.shape
    y0 = np.floor(yy).astype(np.int64)
    x0 = np.floor(xx).astype(np.int64)
    y1 = y0 + 1
    x1 = x0 + 1
    wy = yy - y0
    wx = xx - x0

    def get(iy: np.ndarray, ix: np.ndarray) -> np.ndarray:
        valid = (iy >= 0) & (iy < h) & (ix >= 0) & (ix < w)
        out = np.zeros(iy.shape, dtype=np.float32)
        out[valid] = image[iy[valid], ix[valid]].astype(np.float32)
        return out

    v00 = get(y0, x0)
    v01 = get(y0, x1)
    v10 = get(y1, x0)
    v11 = get(y1, x1)
    top = v00 * (1.0 - wx) + v01 * wx
    bottom = v10 * (1.0 - wx) + v11 * wx
    return top * (1.0 - wy) + bottom * wy


def warp_translation_bilinear(image: np.ndarray, dx: float, dy: float) -> np.ndarray:
    """Warp ``image`` back by sampling at (y + dy, x + dx).

    This is the geometric-transform + interpolation block of the software
    reference path.  The RTL MVP uses integer shifts; the sub-pixel version is
    kept here for accuracy comparison and for generating future test vectors.
    """
    a = np.asarray(image, dtype=np.float32)
    h, w = a.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    return _bilinear_sample(a, yy + float(dy), xx + float(dx))


def _shift_image(image: np.ndarray, dx: int, dy: int) -> np.ndarray:
    """Shift image content by (dx, dy), filling exposed borders with zero."""
    a = np.asarray(image)
    out = np.zeros_like(a)
    h, w = a.shape
    src_y0 = max(0, -dy)
    src_y1 = min(h, h - dy)
    src_x0 = max(0, -dx)
    src_x1 = min(w, w - dx)
    if src_y1 > src_y0 and src_x1 > src_x0:
        out[src_y0 + dy : src_y1 + dy, src_x0 + dx : src_x1 + dx] = a[src_y0:src_y1, src_x0:src_x1]
    return out


def estimate_translation(
    prev: np.ndarray,
    curr: np.ndarray,
    roi: int = 96,
    search: int = 8,
    subpixel: bool = True,
    normalize: bool = True,
) -> Dict[str, object]:
    """Estimate integer translation by exhaustive SAD search.

    Parameters
    ----------
    prev, curr:
        2-D grayscale frames.  They are percentile-normalized independently,
        matching the PS/PL preprocessing convention.
    roi:
        Side length of the central square search template.
    search:
        Maximum absolute integer displacement in pixels.
    subpixel:
        If true, fit a parabola to the 3x3 SAD neighborhood around the best
        integer candidate and return fractional dx/dy as well.

    Returns
    -------
    dict with dx, dy, dx_int, dy_int, sad, sad_mean, roi, search.
    """
    p = (normalize_u8(prev) if normalize else np.asarray(prev, dtype=np.uint8)).astype(np.int16)
    c = (normalize_u8(curr) if normalize else np.asarray(curr, dtype=np.uint8)).astype(np.int16)
    if p.shape != c.shape:
        raise ValueError(f"frame shape mismatch: {p.shape} vs {c.shape}")
    h, w = p.shape
    roi = max(8, min(int(roi), h, w))
    search = max(0, min(int(search), (min(h, w) - roi) // 2))
    cy, cx = h // 2, w // 2
    y0 = cy - roi // 2
    x0 = cx - roi // 2
    ref = p[y0 : y0 + roi, x0 : x0 + roi]

    costs: Dict[Tuple[int, int], int] = {}
    best_cost = None
    best_dx = 0
    best_dy = 0
    for dy in range(-search, search + 1):
        yy = y0 + dy
        if yy < 0 or yy + roi > h:
            continue
        for dx in range(-search, search + 1):
            xx = x0 + dx
            if xx < 0 or xx + roi > w:
                continue
            cost = int(np.abs(ref - c[yy : yy + roi, xx : xx + roi]).sum())
            costs[(dx, dy)] = cost
            if best_cost is None or cost < best_cost:
                best_cost = cost
                best_dx = dx
                best_dy = dy

    if best_cost is None:
        raise ValueError("search window does not fit inside the image")

    fx = float(best_dx)
    fy = float(best_dy)
    if subpixel:
        c0 = costs.get((best_dx - 1, best_dy))
        c1 = costs.get((best_dx, best_dy))
        c2 = costs.get((best_dx + 1, best_dy))
        if c0 is not None and c1 is not None and c2 is not None:
            den = c0 - 2 * c1 + c2
            if den > 0:
                fx += max(-0.5, min(0.5, 0.5 * (c0 - c2) / den))
        c0 = costs.get((best_dx, best_dy - 1))
        c1 = costs.get((best_dx, best_dy))
        c2 = costs.get((best_dx, best_dy + 1))
        if c0 is not None and c1 is not None and c2 is not None:
            den = c0 - 2 * c1 + c2
            if den > 0:
                fy += max(-0.5, min(0.5, 0.5 * (c0 - c2) / den))

    return {
        "dx": float(fx),
        "dy": float(fy),
        "dx_int": int(best_dx),
        "dy_int": int(best_dy),
        "sad": int(best_cost),
        "sad_mean": float(best_cost) / float(roi * roi),
        "roi": int(roi),
        "search": int(search),
    }


def registration_pair(
    prev: np.ndarray,
    curr: np.ndarray,
    roi: int = 96,
    search: int = 8,
    subpixel: bool = True,
    normalize: bool = True,
) -> Dict[str, object]:
    """Return registration parameters and a bilinearly warped current frame."""
    result = estimate_translation(prev, curr, roi=roi, search=search, subpixel=subpixel, normalize=normalize)
    result["warped"] = warp_translation_bilinear(normalize_u8(curr), result["dx"], result["dy"])
    return result


def lv_metrics(mask: np.ndarray, spacing: Sequence[float]) -> Dict[str, object]:
    """Measure LV-cavity area and long-axis extent from a binary mask.

    CAMUS ground truth uses label 1 for the LV cavity.  The long axis is
    estimated as the vertical extent of the cavity in this 2-D 4CH view.  This
    is an engineering approximation, not a clinical biplane measurement.
    """
    m = np.asarray(mask) == 1
    n = int(m.sum())
    sy, sx = float(spacing[0]), float(spacing[1])
    if n == 0:
        return {
            "area_pixels": 0,
            "area_mm2": 0.0,
            "long_axis_px": 0,
            "long_axis_mm": 0.0,
            "bbox": [0, 0, 0, 0],
        }
    ys, xs = np.where(m)
    y0, y1 = int(ys.min()), int(ys.max())
    x0, x1 = int(xs.min()), int(xs.max())
    long_px = y1 - y0 + 1
    return {
        "area_pixels": n,
        "area_mm2": float(n) * sx * sy,
        "long_axis_px": int(long_px),
        "long_axis_mm": float(long_px) * sy,
        "bbox": [x0, y0, x1, y1],
    }


def volume_ml(area_mm2: float, length_mm: float) -> float:
    """Area-length LV volume estimate in millilitres (single-plane 2-D echo)."""
    if length_mm <= 0 or area_mm2 < 0:
        return 0.0
    return (8.0 * area_mm2 * area_mm2 / (3.0 * math.pi * length_mm)) / 1000.0


def select_ed_es(areas: Sequence[float], smooth_window: int = 1) -> Tuple[int, int]:
    """Select ED (largest area) and ES (smallest area) frame indices."""
    if not areas:
        raise ValueError("empty area sequence")
    a = np.asarray(areas, dtype=np.float64)
    if smooth_window and smooth_window > 1:
        kernel = np.ones(int(smooth_window), dtype=np.float64) / float(smooth_window)
        a = np.convolve(a, kernel, mode="same")
    return int(np.argmax(a)), int(np.argmin(a))


def boundary_side_lengths(mask: np.ndarray) -> List[float]:
    """Approximate left/right endocardial boundary path lengths.

    For each row containing the LV cavity, the minimum and maximum x pixels
    are treated as the two endocardial borders.  Summing Euclidean distances
    between adjacent row points gives two boundary lengths.
    """
    m = np.asarray(mask) == 1
    ys = np.flatnonzero(m.any(axis=1))
    if ys.size < 2:
        return [0.0, 0.0]
    left: List[Tuple[int, int]] = []
    right: List[Tuple[int, int]] = []
    for y in ys:
        xs = np.flatnonzero(m[y])
        if xs.size:
            left.append((int(y), int(xs.min())))
            right.append((int(y), int(xs.max())))

    def plen(points: Sequence[Tuple[int, int]]) -> float:
        return sum(
            math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1])
            for i in range(1, len(points))
        )

    return [plen(left), plen(right)]


def gls_surrogate(ed_mask: np.ndarray, es_mask: np.ndarray) -> Dict[str, object]:
    """Simplified GLS surrogate from endocardial boundary path lengths.

    This is *not* speckle-tracking GLS.  It is a transparent engineering
    surrogate that is reproducible from a segmentation mask and can be mapped
    to a path-length or long-axis length calculation in RTL.
    """
    ed_sides = boundary_side_lengths(ed_mask)
    es_sides = boundary_side_lengths(es_mask)
    sides = []
    for a, b in zip(ed_sides, es_sides):
        sides.append((b - a) / a * 100.0 if a > 0 else 0.0)
    return {
        "gls_percent": float(np.mean(sides)) if sides else None,
        "gls_sides_percent": [float(v) for v in sides],
        "ed_boundary_mm_approx": [float(v) for v in ed_sides],
        "es_boundary_mm_approx": [float(v) for v in es_sides],
        "method": "endocardial boundary path-length strain surrogate",
    }


def compute_patient(
    patient_dir: Path | str,
    view: str = "4CH",
    registration_frames: int = 6,
    roi: int = 96,
    search: int = 8,
    subpixel: bool = True,
) -> Dict[str, object]:
    """Compute registration and cardiac metrics for one CAMUS patient."""
    patient_dir = Path(patient_dir)
    pid = patient_dir.name
    view = view.upper()
    if view not in ("2CH", "4CH"):
        raise ValueError("view must be 2CH or 4CH")

    image_path = patient_dir / f"{pid}_{view}_half_sequence.nii.gz"
    gt_path = patient_dir / f"{pid}_{view}_half_sequence_gt.nii.gz"
    img, im = read_nii_gz(image_path)
    gt, gm = read_nii_gz(gt_path)
    if img.ndim != 3 or gt.ndim != 3:
        raise ValueError("expected 3-D CAMUS half-sequence volumes")
    if img.shape[:2] != gt.shape[:2]:
        raise ValueError(f"image/GT spatial size mismatch: {img.shape} vs {gt.shape}")

    n = min(img.shape[2], gt.shape[2])
    spacing = im["spacing"]
    metrics: List[Dict[str, object]] = []
    for t in range(n):
        row = lv_metrics(gt[:, :, t], spacing)
        row["frame"] = t
        metrics.append(row)

    ed, es = select_ed_es([float(r["area_mm2"]) for r in metrics])
    edv = volume_ml(float(metrics[ed]["area_mm2"]), float(metrics[ed]["long_axis_mm"]))
    esv = volume_ml(float(metrics[es]["area_mm2"]), float(metrics[es]["long_axis_mm"]))
    ef = (edv - esv) / edv * 100.0 if edv > 0 else 0.0
    gls = gls_surrogate(gt[:, :, ed] == 1, gt[:, :, es] == 1)
    la_strain = (
        (float(metrics[es]["long_axis_mm"]) - float(metrics[ed]["long_axis_mm"]))
        / float(metrics[ed]["long_axis_mm"])
        * 100.0
        if float(metrics[ed]["long_axis_mm"]) > 0
        else 0.0
    )

    registrations: List[Dict[str, object]] = []
    for t in range(min(int(registration_frames), max(0, n - 1))):
        reg = estimate_translation(
            img[:, :, t], img[:, :, t + 1], roi=roi, search=search, subpixel=subpixel
        )
        registrations.append({"frame_a": t, "frame_b": t + 1, **reg})

    return {
        "patient": pid,
        "view": view,
        "frames": n,
        "spacing_mm": spacing[:2],
        "ed_frame": ed,
        "es_frame": es,
        "edv_ml": edv,
        "esv_ml": esv,
        "ef_percent": ef,
        "gls_percent": gls["gls_percent"],
        "gls_sides_percent": gls["gls_sides_percent"],
        "gls_method": gls["method"],
        "long_axis_shortening_percent": la_strain,
        "registration": registrations,
        "per_frame": metrics,
        "formula": {
            "area_mm2": "N_pixels * sx * sy",
            "volume_ml": "8 * area_mm2^2 / (3*pi*length_mm) / 1000",
            "ef_percent": "(EDV-ESV)/EDV*100",
            "strain_percent": "(L-L0)/L0*100",
        },
        "notes": [
            "EDV/ESV use a single-plane area-length approximation, not 3-D biplane volume.",
            "GLS is an endocardial-boundary path-length surrogate, not clinical speckle tracking.",
        ],
    }


def official_split(split_file: Path | str) -> List[str]:
    """Read a CAMUS official split text file into patient directory names."""
    names = []
    for line in Path(split_file).read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if value:
            names.append(value)
    return names


def write_json(path: Path | str, data: object) -> None:
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--patient-dir", type=Path, required=True)
    parser.add_argument("--view", choices=("2CH", "4CH"), default="4CH")
    parser.add_argument("--registration-frames", type=int, default=6)
    parser.add_argument("--roi", type=int, default=96)
    parser.add_argument("--search", type=int, default=8)
    parser.add_argument("--no-subpixel", action="store_true")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args(argv)

    result = compute_patient(
        args.patient_dir,
        view=args.view,
        registration_frames=args.registration_frames,
        roi=args.roi,
        search=args.search,
        subpixel=not args.no_subpixel,
    )
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())




