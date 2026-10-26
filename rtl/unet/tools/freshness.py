"""Fail a PL build if generated neural-network RTL no longer matches its inputs."""
import argparse
import hashlib
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
def configuration(name):
    if name=='unet':
        config=ROOT/'rtl/unet/model_config.json'
        if config.is_file() and json.loads(config.read_text())['backend']=='small-int8':
            source=[ROOT/'rtl/unet/small_hls'/n for n in ('small_unet.cpp','small_unet.h','model_layout_small.h','model_load.tcl','build_hls.tcl')]
            source += [config,ROOT/'rtl/unet/tools/export_small_model.py']
            source += [ROOT/'smallerseger/cardiac_fpga_ip'/n for n in ('weights_fpga_q8.bin','quant_params_fpga_q20_q12.bin','hls_src/model_layout_fpga5.h')]
            return ROOT/'rtl/unet/small_generated',source
        directory=ROOT/'rtl/unet/generated'
        source=[ROOT/'rtl/unet/hls'/n for n in ('unet_ddr_core.cpp','unet_ddr_core.h','unet_conv.h','model_ops.h','build_hls.tcl')]
        source += [ROOT/'rtl/unet/tools/export_model.py',next((ROOT/'ip/ai4chamberseger').glob('*.zip'))]
    else:
        directory=ROOT/'rtl/inter_fr/ddr/generated'
        source=[ROOT/'rtl/inter_fr/ddr'/n for n in ('registration_ddr.cpp','build_hls.tcl')]
        source += [ROOT/'rtl/unet/hls/unet_ddr_core.h']
    return directory,source
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(name,record):
    directory,source=configuration(name);manifest=directory/'source_fingerprint.json'
    if record:
        files=source+[p for p in sorted(directory.iterdir()) if p.suffix in ('.v','.dat','.tcl')]
        manifest.write_text(json.dumps({p.relative_to(ROOT).as_posix():digest(p) for p in files},indent=2,ensure_ascii=False),encoding='utf-8')
    else:
        expected=json.loads(manifest.read_text(encoding='utf-8'))
        bad=[name for name,sha in expected.items() if not (ROOT/name).is_file() or digest(ROOT/name)!=sha]
        if bad:raise RuntimeError('Generated RTL is stale or modified; regenerate with the HLS script: '+', '.join(bad))
    print(name.upper()+'_RTL_FRESH')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--record',choices=('unet','registration'));p.add_argument('--check',action='store_true')
    a=p.parse_args()
    if a.record:run(a.record,True)
    elif a.check:
        for name in ('unet','registration'):run(name,False)
    else:p.error('choose --record or --check')
