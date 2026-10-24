"""Validate actual CardiacUDA annotations with XSim; never modifies the dataset."""
import argparse
import csv
import json
from pathlib import Path
import subprocess

from prepare_cardiac_annotations import prepare

ROOT = Path(__file__).resolve().parents[3]


def run_checks(data, out, vivado_bin, pixel_case, reuse=False):
    out.mkdir(parents=True, exist_ok=True)
    records = (json.loads((out / 'cases.json').read_text(encoding='utf-8')) if reuse
               else prepare(data, out, pixel_case))
    accepted = [record for record in records if record.get('accepted')]
    if pixel_case not in {record['name'] for record in accepted}:
        raise ValueError('Pixel-stream case must have canonical labels 0..4: ' + pixel_case)
    sim = out / 'xsim'
    sim.mkdir(exist_ok=True)

    def run(name, tool, *args, timeout=180):
        if tool == 'xsim':
            # Xilinx Windows .bat wrappers split unquoted equals signs.
            # An argument file keeps each plusarg intact.
            argfile = sim / (name + '.args')
            argfile.write_text('\n'.join(
                str(arg) if str(arg).startswith('-') else '"' + str(arg) + '"'
                for arg in args), encoding='ascii')
            args = ('-f', argfile.as_posix())
        result = subprocess.run([str(vivado_bin / (tool + '.bat')), *map(str, args)],
                                cwd=sim, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout)
        text = result.stdout.decode('utf-8', 'replace')
        (sim / (name + '.log')).write_text(text, encoding='utf-8')
        if result.returncode or 'ERROR:' in text or 'Fatal:' in text:
            raise RuntimeError(name + '\n' + text[-5000:])
        if tool == 'xsim' and '[PASS]' not in text:
            raise RuntimeError(name + ' did not reach PASS')
        print(name + ': OK', flush=True)
        return text

    rtl = ROOT / 'rtl/heart_analysis'
    run('compile', 'xvlog', '--sv', rtl / 'mask_volume_estimator.v',
        rtl / 'ed_es_tracker.v', rtl / 'medical_accel_top.v',
        rtl / 'tests/tb_cardiac_real_phases.sv', rtl / 'tests/tb_cardiac_real_pixels.sv')
    run('phases_elaborate', 'xelab', 'tb_cardiac_real_phases', '-s', 'real_phases')
    run('pixels_elaborate', 'xelab', 'tb_cardiac_real_pixels', '-s', 'real_pixels')
    for record in accepted:
        folder = Path(record['out'])
        run(record['name'] + '_phases', 'xsim', 'real_phases',
            '-testplusarg', 'FRAMES=' + str(record['frames']),
            '-testplusarg', 'INPUT=' + (folder / 'volumes.hex').as_posix(),
            '-testplusarg', 'OUTPUT=' + (folder / 'phase_pairs.csv').as_posix(), '-runall')
    selected = next(record for record in accepted if record['name'] == pixel_case)
    folder = Path(selected['out'])
    if not (folder / 'mask_frames/frame_000.hex').is_file():
        raise ValueError('Missing real mask fixtures; rerun without --reuse-prepared')
    run(pixel_case + '_pixels', 'xsim', 'real_pixels',
        '-testplusarg', 'FRAMES=' + str(selected['frames']),
        '-testplusarg', 'MASK_DIR=' + (folder / 'mask_frames').as_posix(),
        '-testplusarg', 'INPUT=' + (folder / 'volumes.hex').as_posix(),
        '-testplusarg', 'OUTPUT=' + (folder / 'pixel_pairs.csv').as_posix(), '-runall',
        timeout=300)
    if (folder / 'phase_pairs.csv').read_bytes() != (folder / 'pixel_pairs.csv').read_bytes():
        raise AssertionError('Pixel-stream phase pairs differ from the reference-volume sequence')
    print('REAL_ANNOTATION_CHECKS_OK: %d cases, %d frames; pixel stream %s / %d pixels' %
          (len(accepted), sum(record['frames'] for record in accepted), pixel_case,
           selected['frames'] * 65536), flush=True)
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True, help='CardiacUDA label_all_frame directory')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/tests/medical_real')
    parser.add_argument('--vivado-bin', type=Path, default=Path('E:/Xilinx/Vivado/2023.2/bin'))
    parser.add_argument('--pixel-case', default='normal-23-4')
    parser.add_argument('--reuse-prepared', action='store_true', help='Explicitly reuse previously prepared fixtures')
    args = parser.parse_args()
    if not args.data.is_dir():
        parser.error('Source annotation directory does not exist')
    run_checks(args.data.resolve(), args.out.resolve(), args.vivado_bin.resolve(),
               args.pixel_case, args.reuse_prepared)
