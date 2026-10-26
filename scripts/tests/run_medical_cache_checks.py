from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/tests/medical_cache';OUT.mkdir(parents=True,exist_ok=True)
BIN=Path('E:/Xilinx/Vivado/2023.2/bin')
def run(name,args):
 p=subprocess.run(args,cwd=OUT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 s=p.stdout.decode('utf-8','replace');(OUT/(name+'.log')).write_text(s,encoding='utf-8')
 if p.returncode or 'ERROR:' in s or 'Fatal:' in s:raise RuntimeError(name+'\n'+s[-5000:])
 print(name+': OK',flush=True);return s
run('compile',[str(BIN/'xvlog.bat'),'--sv',*[str(ROOT/p) for p in ['rtl/medical_cache_input.v','rtl/heart_analysis/mask_to_contour.v','sim/tb/tb_medical_cache.sv']]])
run('elaborate',[str(BIN/'xelab.bat'),'tb_medical_cache','-s','medical_cache'])
(OUT/'run.tcl').write_text('run all\nquit\n')
s=run('simulate',[str(BIN/'xsim.bat'),'medical_cache','-tclbatch','run.tcl'])
if '[PASS]' not in s:raise RuntimeError('no PASS')
