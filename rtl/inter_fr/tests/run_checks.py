"""Local XSim checks for registration and input routing; no synthesis."""
from pathlib import Path
import argparse
import subprocess

HERE = Path(__file__).resolve().parent
RTL = HERE.parent
ROOT = RTL.parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=ROOT / 'build/tests/inter_fr')
    parser.add_argument('--vivado-bin', type=Path, default=Path('E:/Xilinx/Vivado/2023.2/bin'))
    parser.add_argument('--top', action='append', choices=('tb_sad_pipeline',
                        'tb_registration_search', 'tb_registration_perf',
                        'tb_registration_stream', 'tb_registration_interval', 'tb_frame_xbar'))
    options = parser.parse_args()
    out = options.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(name, tool, *args):
        result = subprocess.run([str(options.vivado_bin / (tool + '.bat')), *map(str, args)],
                                cwd=out, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        text = result.stdout.decode('utf-8', 'replace')
        (out / (name + '.log')).write_text(text, encoding='utf-8')
        if result.returncode or 'ERROR:' in text or 'Fatal:' in text:
            raise RuntimeError(name + ':\n' + text[-6000:])
        print(name + ': OK', flush=True)
        return text

    run('compile', 'xvlog', '--sv', *sorted(RTL.glob('*.v')), ROOT / 'rtl/frame_xbar.v',
        *sorted(HERE.glob('tb_*.sv')), ROOT / 'sim/tb/tb_frame_xbar.sv')
    for name in (options.top or ('tb_sad_pipeline', 'tb_registration_search', 'tb_registration_perf',
                 'tb_registration_stream', 'tb_registration_interval', 'tb_frame_xbar')):
        run(name + '_elaborate', 'xelab', name, '-s', name)
        result = run(name, 'xsim', name, '-runall')
        if '[PASS]' not in result:
            raise RuntimeError(name + ' did not reach PASS')
        for line in result.splitlines():
            if '[PASS]' in line or 'clocks' in line:
                print(line, flush=True)


if __name__ == '__main__':
    main()
