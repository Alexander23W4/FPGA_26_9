#!/usr/bin/env python3
"""Prepare CAMUS BIN files for the teammate eMMC upload workflow.

Output is always 256x256x8 raw data, 65536 bytes, no header.
"""
from __future__ import annotations
import argparse, csv, shutil, zlib
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, default=Path(r'C:/Users/13995/Desktop/fpga校赛/camus_processed'))
    parser.add_argument('--output', type=Path, default=Path(r'C:/Users/13995/Desktop/fpga校赛/board_upload'))
    parser.add_argument('--cases', default='4CH_ED,4CH_ES,2CH_ED,2CH_ES')
    parser.add_argument('--patients', default='patient0001,patient0002,patient0003')
    parser.add_argument('--copy', action='store_true')
    args = parser.parse_args()
    patients = [x.strip() for x in args.patients.split(',') if x.strip()]
    cases = [x.strip() for x in args.cases.split(',') if x.strip()]
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for patient in patients:
        for case in cases:
            src = args.input / 'images' / 'training' / patient / f'{patient}_{case}.bin'
            if not src.is_file():
                print('missing:', src)
                continue
            data = src.read_bytes()
            if len(data) != 65536:
                raise ValueError(f'{src}: expected 65536 bytes, got {len(data)}')
            name = f'{patient}_{case}.bin'
            dst = args.output / name
            if args.copy:
                shutil.copy2(src, dst)
            rows.append({
                'file': str(dst if args.copy else src),
                'source': str(src),
                'name': name[:-4],
                'width': 256,
                'height': 256,
                'bpp': 1,
                'bytes': len(data),
                'crc32': f'{zlib.crc32(data) & 0xffffffff:08X}',
            })
    manifest = args.output / 'manifest.csv'
    with manifest.open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=['file','source','name','width','height','bpp','bytes','crc32'])
        w.writeheader(); w.writerows(rows)
    print(manifest)
    print(f'images={len(rows)} copied={args.copy}')

if __name__ == '__main__':
    main()
