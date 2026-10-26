from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'build/tests/unet_cdc';OUT.mkdir(parents=True,exist_ok=True)
BIN=Path('E:/Xilinx/Vivado/2023.2/bin')
def run(name,args):
 r=subprocess.run(args,cwd=OUT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 s=r.stdout.decode('utf-8','replace');(OUT/(name+'.log')).write_text(s,encoding='utf-8')
 if r.returncode or 'Fatal:' in s or 'ERROR:' in s:raise RuntimeError(name+'\n'+s[-4000:])
 print(name+': OK',flush=True);return s
files=[ROOT/'rtl/reset_sync.v',ROOT/'rtl/unet/unet_stream_cdc.v',ROOT/'rtl/unet/unet_status_cdc.v',ROOT/'rtl/unet/tests/tb_unet_cdc.sv',BIN.parent/'data/verilog/src/glbl.v']
run('compile',[str(BIN/'xvlog.bat'),'--sv',*[str(x) for x in files]])
(OUT/'run.tcl').write_text('run all\nquit\n')
for label,half in [('160',3.125),('200',2.5),('250',2.0)]:
 run('elab_'+label,[str(BIN/'xelab.bat'),'--relax','-L','xpm','-L','unisims_ver','tb_unet_cdc'+label,'glbl','-s','cdc_'+label])
 s=run('run_'+label,[str(BIN/'xsim.bat'),'cdc_'+label,'-tclbatch','run.tcl'])
 if '[PASS]' not in s:raise RuntimeError('no PASS')
print('UNET_CDC_VERIFIED',flush=True)
