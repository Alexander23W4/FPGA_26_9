"""Actual volume/phase/AXI tests and PS unit conversion; no synthesis or board."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOPS = ('tb_mask_volume', 'tb_cardiac_phases', 'tb_cardiac_temporal_regression', 'tb_medical_volumes',
        'tb_volume_range', 'tb_medical_stream', 'tb_display_regs', 'tb_system_mode')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=ROOT / 'build/tests/medical')
    parser.add_argument('--vivado-bin', type=Path, default=Path('E:/Xilinx/Vivado/2023.2/bin'))
    args = parser.parse_args()
    out = args.out.resolve()
    command = [sys.executable, str(ROOT / 'scripts/tests/run_display_checks.py'),
               '--out', str(out), '--vivado-bin', str(args.vivado_bin)]
    for top in TOPS:
        command.extend(('--top', top))
    subprocess.run(command, cwd=ROOT, check=True)
    for top in TOPS:
        for line in (out / (top + '.log')).read_text(encoding='utf-8').splitlines():
            if '[PASS]' in line or line.startswith('PAIR '):
                print(line, flush=True)
    compiler = args.vivado_bin.parent / 'tps/mingw/9.3.0/win64.o/nt/bin/gcc.exe'
    executable = out / 'test_volume_units.exe'
    subprocess.run([str(compiler), '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-static',
                    '-I' + str(ROOT / 'csrc/MID_plt/src'),
                    str(ROOT / 'rtl/heart_analysis/tests/test_volume_units.c'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=10)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'network/host',
                    '-p', 'test_display_registers.py'], cwd=ROOT, check=True)
    print('MEDICAL_CHECKS_OK', flush=True)


if __name__ == '__main__':
    main()
