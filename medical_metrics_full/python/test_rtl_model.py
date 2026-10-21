#!/usr/bin/env python3
import unittest
import rtl_model


class RtlArithmeticTests(unittest.TestCase):
    def test_divider(self):
        self.assertEqual(rtl_model.div_u64(100, 7), 14)
        self.assertEqual(rtl_model.div_u64(0, 7), 0)
        self.assertEqual(rtl_model.div_u64(7, 0), 0)

    def test_volume_q16(self):
        self.assertEqual(rtl_model.volume_q16(200, 10, 24, 79), 6337)

    def test_strain_q16(self):
        self.assertEqual(rtl_model.strain_q16(100, 80), -1310720)
        self.assertEqual(rtl_model.strain_q16(100, 120), 1310720)


if __name__ == "__main__":
    unittest.main(verbosity=2)
