"""Pack the colleague's trained INT8 student without changing its parameters."""
from pathlib import Path
import hashlib
import json
import re
import struct
import zlib
import numpy as np

ROOT=Path(__file__).resolve().parents[3]

def export():
    source=ROOT/'smallerseger/cardiac_fpga_ip'
    config=json.loads((ROOT/'rtl/unet/model_config.json').read_text())
    lanes=config['lanes']
    if lanes not in (4,8):raise ValueError('supported output parallelism is four or eight lanes')
    layout=(source/'hls_src/model_layout_fpga5.h').read_text()
    definitions={name:int(value) for name,value in re.findall(r'#define\s+(\w+)\s+(\d+)\s*$',layout,re.M)}
    code=(source/'hls_src/unet_infer_axis.cpp').read_text()
    calls=re.findall(r'conv2d_q8\(workspace\+\w+,\s*(?:0|workspace\+\w+),\s*workspace\+\w+,\s*weights,\s*params,\s*(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),W_(\w+),P_\w+,(\d+)',code)
    if len(calls)!=15:raise ValueError('expected all fifteen trained convolutions')
    weights=np.fromfile(source/'weights_fpga_q8.bin',dtype=np.int8)
    params=(source/'quant_params_fpga_q20_q12.bin').read_bytes()
    if len(weights)!=definitions['WEIGHT_BYTES'] or len(params)!=4*definitions['PARAM_I32_COUNT']:
        raise ValueError('truncated trained weights or quantization parameters')
    blocks=[];offset=0;ops=[];macs=0
    for ci0,ci1,co,h,w,k,name,relu in calls:
        ci=int(ci0)+int(ci1);co,h,w,k=map(int,(co,h,w,k))
        start=definitions['W_'+name];count=co*ci*k*k
        original=weights[start:start+count].reshape(co,ci,k,k)
        padded=np.zeros((((co+lanes-1)//lanes)*lanes,ci,k,k),dtype=np.int8);padded[:co]=original
        packed=padded.reshape(-1,lanes,ci,k,k).transpose(0,2,3,4,1).copy().reshape(-1)
        layout=re.sub(r'(#define W_'+name+r' )\d+',lambda m:m[1]+str(offset),layout)
        blocks.append(packed.tobytes());ops.append(dict(name=name,cin=ci,cout=co,h=h,w=w,k=k,relu=int(relu),weight_offset=offset,param_offset=definitions['P_'+name]))
        offset+=len(packed);macs+=h*w*co*ci*k*k
    payload=b''.join(blocks);param_offset=16+len(payload)//4
    identity=hashlib.sha256(payload+params+json.dumps(config,sort_keys=True).encode()+layout.encode()).digest()
    program_id=zlib.crc32(identity)
    header=[0,2,15,definitions['WS_ELEMENTS'],lanes,256,program_id,len(payload)//4,param_offset,len(params)//4]+[0]*6
    blob=struct.pack('<16I',*header)+payload+params
    layout=re.sub(r'#define OC_TILE \d+',f'#define OC_TILE {lanes}',layout)
    layout=re.sub(r'#define WEIGHT_BYTES \d+',f'#define WEIGHT_BYTES {len(payload)}',layout)
    layout+=f'\n#define SMALL_PROGRAM_ID {program_id}u\n#define SMALL_WEIGHT_OFFSET 16u\n#define SMALL_PARAM_OFFSET {param_offset}u\n#define SMALL_WEIGHT_WORDS {len(blob)//4}u\n'
    target=ROOT/'rtl/unet/small_hls'
    (target/'model_layout_small.h').write_text(layout)
    (target/'model_load.tcl').write_text('set ::unet_expected_header {'+' '.join(map(str,header[:7]))+'}\n')
    out=ROOT/'build/unet/model';out.mkdir(parents=True,exist_ok=True)
    graph=dict(format_version=2,architecture='FPGAUNet8_16_32_64_INT8_Q12',lanes=lanes,image_size=256,
               workspace_words=definitions['WS_ELEMENTS'],workspace_bytes=4*definitions['WS_ELEMENTS'],
               macs_per_frame=macs,program_id=program_id,ops=ops,weights_sha256=hashlib.sha256(blob).hexdigest(),
               source_weights_sha256=hashlib.sha256(weights.tobytes()).hexdigest(),source_params_sha256=hashlib.sha256(params).hexdigest(),
               class_ids=config['classes'],class_mapping_verified=False)
    (out/'weights.bin').write_bytes(blob)
    (out/'model.json').write_text(json.dumps(graph,indent=2)+'\n')
    print(f'SMALL_MODEL_EXPORTED bytes={len(blob)} MACs={macs} program={program_id} lanes={lanes}')

if __name__=='__main__':export()
