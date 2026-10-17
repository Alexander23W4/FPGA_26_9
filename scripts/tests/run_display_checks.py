"""Small RTL simulations with Vivado XSim; never runs synthesis or accesses a board."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vivado-bin', default='E:/Xilinx/Vivado/2023.2/bin')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/tests/display')
    parser.add_argument('--top', action='append', choices=('tb_display_regs',
                        'tb_back_stream', 'tb_hdmi_out', 'tb_video_colorizer', 'tb_top_thr', 'tb_independent_return'),
                        help='Run selected local testbench; may be repeated')
    args = parser.parse_args()
    args.out = args.out.resolve()
    binary = Path(args.vivado_bin)
    args.out.mkdir(parents=True, exist_ok=True)
    def run(name, *command):
        argv = [item.as_posix() if isinstance(item, Path) else str(item) for item in command]
        result = subprocess.run(argv, cwd=args.out,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        output = result.stdout.decode('utf-8', 'replace')
        (args.out / (name + '.log')).write_text(output, encoding='utf-8')
        if result.returncode or 'ERROR:' in output or 'Fatal:' in output or '[FAIL]' in output:
            raise RuntimeError(name + ' failed:\n' + output[-7000:])
        print(name + ': OK', flush=True)
        return output
    sources = sorted((ROOT / 'rtl').rglob('*.v'))
    tests = [ROOT / 'sim/tb/tb_display_regs.sv', ROOT / 'sim/tb/tb_video_colorizer.sv',
             ROOT / 'sim/tb/tb_hdmi_out.v', ROOT / 'sim/tb/tb_top_thr.v',
             ROOT / 'sim/tb/tb_back_stream.sv', ROOT / 'sim/tb/tb_independent_return.sv']
    run('compile', binary/'xvlog.bat', '--sv', '--relax', '--work', 'xil_defaultlib', *sources, *tests,
        binary.parent/'data/verilog/src/glbl.v')
    run('top1_elaborate', binary/'xelab.bat', '--relax', '-L', 'unisims_ver',
        'xil_defaultlib.top1', 'xil_defaultlib.glbl', '-s', 'top1_ports')
    script = args.out / 'run.tcl'
    script.write_text('run all\nquit\n', encoding='ascii')
    for top in (args.top or ('tb_display_regs', 'tb_back_stream', 'tb_hdmi_out', 'tb_video_colorizer', 'tb_top_thr', 'tb_independent_return')):
        run(top+'_elaborate', binary/'xelab.bat', '--relax', 'xil_defaultlib.'+top, '-s', top)
        output = run(top, binary/'xsim.bat', top, '-tclbatch', script, '-onerror', 'quit')
        if '[PASS]' not in output:
            raise RuntimeError(top+' produced no PASS marker; inspect '+str(args.out))
    print('DISPLAY_CHECKS_OK', flush=True)

if __name__ == '__main__':
    main()
