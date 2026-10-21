#!/usr/bin/env python3
"""Regression tests for the software golden model."""
from __future__ import annotations

import math
import unittest
from pathlib import Path

import numpy as np

import golden_metrics as gm


class GoldenMetricsTests(unittest.TestCase):
    def test_translation_search_exact(self) -> None:
        rng = np.random.default_rng(20261019)
        base = rng.integers(0, 256, size=(160, 160), dtype=np.uint8)
        curr = gm._shift_image(base, dx=3, dy=-2)
        result = gm.estimate_translation(base, curr, roi=80, search=6, subpixel=False, normalize=False)
        self.assertEqual((result["dx_int"], result["dy_int"]), (3, -2))
        self.assertEqual(result["sad"], 0)

    def test_translation_search_negative_large(self) -> None:
        rng = np.random.default_rng(7)
        base = rng.integers(0, 256, size=(128, 128), dtype=np.uint8)
        curr = gm._shift_image(base, dx=-5, dy=4)
        result = gm.estimate_translation(base, curr, roi=64, search=5, subpixel=False, normalize=False)
        self.assertEqual((result["dx_int"], result["dy_int"]), (-5, 4))

    def test_bilinear_warp_identity_and_half_pixel(self) -> None:
        x = np.tile(np.arange(10, dtype=np.float32), (8, 1))
        np.testing.assert_allclose(gm.warp_translation_bilinear(x, 0.0, 0.0), x)
        shifted = gm.warp_translation_bilinear(x, 0.5, 0.0)
        # A +0.5 sample is the average of adjacent source pixels.
        self.assertAlmostEqual(float(shifted[2, 3]), 3.5, places=5)
        self.assertAlmostEqual(float(shifted[2, 0]), 0.5, places=5)

    def test_area_and_volume(self) -> None:
        mask = np.zeros((30, 40), dtype=np.uint8)
        mask[5:15, 3:23] = 1  # 10 rows x 20 columns
        m = gm.lv_metrics(mask, spacing=(0.5, 0.5))
        self.assertEqual(m["area_pixels"], 200)
        self.assertAlmostEqual(m["area_mm2"], 50.0)
        self.assertEqual(m["long_axis_px"], 10)
        expected = 8.0 * 50.0 * 50.0 / (3.0 * math.pi * 5.0) / 1000.0
        self.assertAlmostEqual(gm.volume_ml(50.0, 5.0), expected)

    def test_ed_es_selection(self) -> None:
        ed, es = gm.select_ed_es([100, 80, 60, 40, 60, 90])
        self.assertEqual(ed, 0)
        self.assertEqual(es, 3)

    def test_gls_surrogate_is_negative_when_cavity_contracts(self) -> None:
        ed = np.zeros((80, 80), dtype=np.uint8)
        es = np.zeros((80, 80), dtype=np.uint8)
        ed[10:70, 20:60] = 1
        es[20:60, 28:52] = 1
        result = gm.gls_surrogate(ed, es)
        self.assertLess(result["gls_percent"], 0.0)
        self.assertEqual(len(result["gls_sides_percent"]), 2)

    def test_nifti_round_trip(self) -> None:
        a = np.arange(4 * 5 * 3, dtype=np.int16).reshape((4, 5, 3))
        td = Path(__file__).parent / "_test_tmp"
        td.mkdir(exist_ok=True)
        try:
            p = td / "x.nii.gz"
            gm.write_nii_gz(p, a, spacing=(0.5, 0.25, 2.0))
            b, meta = gm.read_nii_gz(p)
            np.testing.assert_array_equal(a, b)
            self.assertEqual(meta["shape"], [4, 5, 3])
            self.assertAlmostEqual(meta["spacing"][0], 0.5)
            self.assertAlmostEqual(meta["spacing"][1], 0.25)
        finally:
            for child in td.iterdir():
                child.unlink()
            td.rmdir()

    def test_optional_camus_patient0001(self) -> None:
        root = Path(r"C:\Users\13995\Desktop\fpga校赛\CAMUS_public\database_nifti")
        p = root / "patient0001"
        if not p.exists():
            self.skipTest("CAMUS patient0001 not present")
        r = gm.compute_patient(p, registration_frames=2)
        self.assertEqual(r["frames"], 20)
        self.assertEqual((r["ed_frame"], r["es_frame"]), (0, 19))
        self.assertTrue(140.0 < r["edv_ml"] < 155.0)
        self.assertTrue(60.0 < r["esv_ml"] < 75.0)
        self.assertTrue(50.0 < r["ef_percent"] < 58.0)
        self.assertTrue(-30.0 < r["gls_percent"] < -20.0)
        self.assertEqual(r["registration"][0]["dx_int"], 0)
        self.assertEqual(r["registration"][0]["dy_int"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
