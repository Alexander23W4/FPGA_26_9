"""Independent floating-point geometry oracle for the small XSim volume test."""
from pathlib import Path
import math


def write_vectors(out):
    width, height = 16, 8
    inputs, expected = [], []
    for frame in range(20):
        image = []
        for y in range(height):
            row = []
            for x in range(width):
                bits = []
                for chamber in range(4):
                    if frame == 0:
                        hit = False
                    elif frame == 1:
                        hit = True
                    elif frame == 2:
                        hit = x == width - 1 and y == height - 1
                    elif frame == 3:
                        hit = chamber <= x < width - chamber and chamber <= y < height - chamber
                    else:
                        hit = (x * 17 + y * 13 + chamber * 7 + frame * 19) % 23 < 12
                    bits.append(hit)
                row.append(sum(int(hit) << c for c, hit in enumerate(bits)))
            image.append(row)
            inputs.extend(row)
        packed = 0
        for chamber in range(4):
            disc_sum = 0
            for row in image:
                hits = [x for x, mask in enumerate(row) if mask & (1 << chamber)]
                if hits:
                    disc_sum += (hits[-1] - hits[0] + 1) ** 2
            volume = math.floor(math.pi / 4 * disc_sum * 100 + 0.5)
            packed |= volume << (32 * chamber)
        expected.append(packed)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'mask_volume_input.hex').write_text(''.join(f'{v:x}\n' for v in inputs), encoding='ascii')
    (out / 'mask_volume_expected.hex').write_text(''.join(f'{v:032x}\n' for v in expected), encoding='ascii')
    pairs = []
    for lv in (12, 4, 11, 3):
        widths = (16 - lv // 2, 4 + lv // 2, lv, lv + 1)
        values = [math.floor(math.pi / 4 * 14 * w * w * 100 + 0.5) for w in widths]
        pairs.append(sum(v << (32 * c) for c, v in enumerate(values)))
    (out / 'medical_pair_expected.hex').write_text(''.join(f'{v:032x}\n' for v in pairs), encoding='ascii')
