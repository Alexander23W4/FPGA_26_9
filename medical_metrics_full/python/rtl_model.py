#!/usr/bin/env python3
"""Bit-exact reference model for the small RTL arithmetic blocks.

This does not simulate Verilog.  It reproduces the integer operations used by
volume_calc.v and strain_calc.v so their fixed-point constants can be checked
independently of a hardware simulator.
"""
from __future__ import annotations


def div_u64(numerator: int, denominator: int) -> int:
    """Unsigned integer division used by div_u64_u64.v."""
    if denominator == 0:
        return 0
    quotient = 0
    remainder = 0
    for bit in range(63, -1, -1):
        remainder = (remainder << 1) | ((numerator >> bit) & 1)
        if remainder >= denominator:
            remainder -= denominator
            quotient |= (1 << bit)
    return quotient


def volume_q16(area_px: int, length_px: int, pixel_area_q8: int = 24, spacing_y_q8: int = 79) -> int:
    """Q16.16 mL, matching volume_calc.v."""
    area_q8 = int(area_px) * int(pixel_area_q8)
    len_q8 = int(length_px) * int(spacing_y_q8)
    numerator = (area_q8 * area_q8) << 16
    denominator = 301593 * len_q8
    return div_u64(numerator, denominator)


def strain_q16(ed_length_px: int, es_length_px: int) -> int:
    """Signed Q16.16 percent, matching strain_calc.v."""
    ed = int(ed_length_px)
    es = int(es_length_px)
    if ed == 0:
        return 0
    diff = es - ed
    sign = -1 if diff < 0 else 1
    q = div_u64(abs(diff) * 6553600, ed)
    return sign * q
