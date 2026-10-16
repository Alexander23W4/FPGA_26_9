"""Exact Otsu reference vs RTL, current-frame replay, backpressure and BRAM check."""
import argparse
from fractions import Fraction
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def reference(pixels):
    hist = [0]*256
    for pixel in pixels:
        hist[pixel] += 1
    total, gray_sum = len(pixels), sum(pixels)
    w0 = sum0 = 0
    best_score, threshold = Fraction(-1), min(pixels)
    for t, count in enumerate(hist):
        w0 += count
        sum0 += t*count
        if 0 < w0 < total:
            diff = gray_sum*w0 - sum0*total
            score = Fraction(diff*diff, w0*(total-w0))
            if score > best_score:
                best_score, threshold = score, t
    return threshold


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vivado-bin', type=Path, default=Path('E:/Xilinx/Vivado/2023.2/bin'))
    parser.add_argument('--out', type=Path, default=ROOT/'build/tests/otsu')
    parser.add_argument('--synth', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(1701)
    three_bins = [10]*32768+[100]*16384+[220]*16384
    frames = [three_bins, [190]*49152+[230]*16384, [0]*65536, [255]*65536,
              [0, 1]*32768, [rng.randrange(256) for _ in range(65536)],
              [rng.randrange(30) if i < 60000 else rng.randrange(30, 256) for i in range(65536)],
              three_bins]
    thresholds = [reference(frame) for frame in frames]
    (args.out/'pixels.mem').write_text(''.join('%02x\n'%p for frame in frames for p in frame), encoding='ascii')
    (args.out/'thresholds.mem').write_text(''.join('%02x\n'%t for t in thresholds), encoding='ascii')
    print('Exact reference thresholds:', thresholds, flush=True)

    def run(name, *command):
        argv = [item.as_posix() if isinstance(item, Path) else str(item) for item in command]
        result = subprocess.run(argv, cwd=args.out, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=240)
        output = result.stdout.decode('utf-8', 'replace')
        (args.out/(name+'.log')).write_text(output, encoding='utf-8')
        if result.returncode or any(mark in output for mark in ('ERROR:', 'Fatal:', '[FAIL]', "couldn't read file")):
            raise RuntimeError(name+' failed:\n'+output[-7500:])
        print(name+': OK', flush=True)
        return output

    sources = sorted((ROOT/'rtl/thresholder').glob('*.v'))
    benches = [ROOT/'sim/tb/tb_otsu_core.sv', ROOT/'sim/tb/tb_otsu_frame.sv']
    run('compile', args.vivado_bin/'xvlog.bat', '--sv', *sources, *benches)
    script = args.out/'run.tcl'
    script.write_text('run all\nquit\n', encoding='ascii')
    for top in ('tb_otsu_core', 'tb_otsu_frame'):
        run(top+'_elaborate', args.vivado_bin/'xelab.bat', 'work.'+top, '-s', top)
        output = run(top, args.vivado_bin/'xsim.bat', top, '-tclbatch', script, '-onerror', 'quit')
        if '[PASS]' not in output:
            raise RuntimeError(top+' produced no PASS marker')
        print('\n'.join(line for line in output.splitlines() if line.startswith(('CASE', '[PASS]'))), flush=True)
    if args.synth:
        tcl = args.out/'synth.tcl'
        tcl.write_text('\n'.join('read_verilog {%s}'%source.as_posix() for source in sources)+'''
synth_design -top top_threshold_demo -part xc7z015clg485-2 -mode out_of_context
create_clock -period 39.68254 [get_ports clk]
report_utilization -file utilization.rpt
report_timing_summary -file timing_synth.rpt
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $brams] == 0} {error "frame RAM did not infer BRAM"}
puts "OTSU_BRAM_INFERENCE_OK [llength $brams] primitives"
quit
''', encoding='ascii')
        output = run('synth', args.vivado_bin/'vivado.bat', '-mode', 'batch', '-source', tcl)
        if 'OTSU_BRAM_INFERENCE_OK' not in output:
            raise RuntimeError('BRAM inference was not confirmed')
    print('OTSU_CHECKS_OK', flush=True)


if __name__ == '__main__':
    main()
