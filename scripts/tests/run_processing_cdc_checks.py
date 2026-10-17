"""Local xsim regression at unequal clock rates; no board/project mutation."""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/tests/processing_cdc'
BIN = Path('E:/Xilinx/Vivado/2023.2/bin')


def run(tool, *args, log, timeout=240):
    with (OUT/log).open('w', encoding='utf-8') as output:
        result = subprocess.run([str(BIN/(tool+'.bat')), *map(str,args)], cwd=OUT,
                                stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    text = (OUT/log).read_text(encoding='utf-8',errors='replace')
    if result.returncode or 'Fatal:' in text or '[FAIL]' in text:
        raise RuntimeError(f'{tool} failed: {OUT/log}\n{text[-3000:]}')
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--frequencies', type=int, nargs='+', choices=[25,80,100,150], default=[80,100,150,25])
    options = parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    sources = sorted((ROOT/'rtl').rglob('*.v'))
    run('xvlog','--sv',*sources,ROOT/'sim/tb/tb_independent_return.sv',
        ROOT/'sim/tb/tb_processing_cdc.sv',ROOT/'sim/tb/tb_cdc_control.sv',log='compile.out')
    run('xelab','tb_cdc_control','-s','cdc_control','--relax',log='control_elaborate.out')
    control = run('xsim','cdc_control','-runall',log='control_run.out')
    if '[PASS] tb_cdc_control' not in control:
        raise RuntimeError('missing control completion marker')
    print('CDC control: passed',flush=True)
    for frequency in options.frequencies:
        label = str(frequency)+'MHz'
        snapshot = 'cdc_'+label
        run('xelab','tb_processing_cdc_'+str(frequency),'-s',snapshot,'--relax',
            log=f'elaborate_{label}.out')
        text = run('xsim',snapshot,'-runall',log=f'run_{label}.out')
        if '[PASS] tb_independent_return' not in text:
            raise RuntimeError(f'missing completion marker: {label}')
        print(label+': '+next(line for line in text.splitlines() if '[PASS]' in line),flush=True)


if __name__=='__main__':
    main()
