"""Recover the complete MobileNetV2 U-Net from the colleague's float header.

The ip tree is read-only. All tensors are checked against the full architecture;
BN is folded in eval mode. No trained convolution is dropped or substituted.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import zipfile
import zlib
import numpy as np

ROOT = Path(__file__).resolve().parents[3]
FIELDS = ('kind','src','skip','dst','ih','iw','cin','oh','ow','cout',
          'kernel','stride','activation','weights','bias','wlog','skip_c')
CONV, DEPTHWISE, ADD, UPSAMPLE_CAT = 0, 1, 2, 3

def read_float_weights(path):
    if path.suffix.lower() == '.zip':
        with zipfile.ZipFile(path) as archive:
            members = [n for n in archive.namelist() if n.endswith('.h')]
            if len(members) != 1:
                raise ValueError('Expected exactly one float header in archive')
            source = archive.read(members[0]).decode('utf-8-sig')
    else:
        source = path.read_text(encoding='utf-8-sig')
    found = re.findall(r'const\s+float\s+(\w+)\[\]\s*=\s*\{([^}]*)\}', source)
    arrays = {name: np.fromstring(values, sep=',', dtype=np.float32) for name, values in found}
    if len(arrays) != len(found) or not arrays:
        raise ValueError('Duplicate or missing weight arrays')
    if any(not np.isfinite(a).all() for a in arrays.values()):
        raise ValueError('Nonfinite trained parameters')
    return arrays

def build_graph(arrays, lanes=16, image_size=256):
    if lanes not in (4,8,16) or image_size < 32 or image_size & (image_size-1):
        raise ValueError('lanes=4/8/16 and power-of-two image size >=32 required')
    used = set()
    tensors = [dict(name='input', h=image_size, w=image_size, c=1)]
    ops, blocks = [], [np.zeros(16, dtype='<f4')]
    words = 16
    def take(name, shape):
        used.add(name)
        a = arrays[name]
        if a.size != math.prod(shape):
            raise ValueError(f'{name}: {a.size} values, expected {shape}')
        return a.reshape(shape)
    def tensor(name,h,w,c):
        tensors.append(dict(name=name,h=h,w=w,c=c))
        return len(tensors)-1
    def append_blob(a):
        nonlocal words
        pad = (-words) % 16
        if pad: blocks.append(np.zeros(pad,dtype='<f4')); words += pad
        offset = words
        flat = np.asarray(a,dtype='<f4').ravel()
        blocks.append(flat); words += flat.size
        return offset
    def conv(src, name, weight, bn, cout, kernel=1, stride=1, act=0, dw=False):
        t=tensors[src]; cin=t['c']; groups=cin if dw else 1
        w=take(weight,(cout,cin//groups,kernel,kernel)).copy()
        if bn:
            gamma=take(bn+'_weight',(cout,)).astype(np.float64)
            beta=take(bn+'_bias',(cout,)).astype(np.float64)
            mean=take(bn+'_running_mean',(cout,)).astype(np.float64)
            var=take(bn+'_running_var',(cout,)).astype(np.float64)
            if (var<0).any(): raise ValueError('Negative BN variance: '+bn)
            scale=gamma/np.sqrt(var+1e-5)
            w=(w.astype(np.float64)*scale[:,None,None,None]).astype(np.float32)
            bias=(beta-mean*scale).astype(np.float32)
        else:
            bias=take(weight.removesuffix('_weight')+'_bias',(cout,))
        # OIHW -> output-block, KY, KX, input-channel, parallel output-lane.
        padded=((cout+lanes-1)//lanes)*lanes
        wp=np.zeros((padded,cin//groups,kernel,kernel),np.float32);wp[:cout]=w
        packed=wp.reshape(-1,lanes,cin//groups,kernel,kernel).transpose(0,3,4,2,1)
        bp=np.zeros(padded,np.float32);bp[:cout]=bias
        wo=append_blob(packed);bo=append_blob(bp)
        oh=(t['h']+stride-1)//stride;ow=(t['w']+stride-1)//stride
        dst=tensor(name,oh,ow,cout)
        ops.append(dict(kind=DEPTHWISE if dw else CONV,src=src,skip=-1,dst=dst,
            ih=t['h'],iw=t['w'],cin=cin,oh=oh,ow=ow,cout=cout,kernel=kernel,
            stride=stride,activation=act,weights=wo,bias=bo,wlog=ow.bit_length()-1,skip_c=0,name=name))
        return dst
    def add(a,b,name):
        t=tensors[a];assert all(t[k]==tensors[b][k] for k in ('h','w','c'))
        dst=tensor(name,t['h'],t['w'],t['c'])
        ops.append(dict(kind=ADD,src=a,skip=b,dst=dst,ih=t['h'],iw=t['w'],cin=t['c'],
            oh=t['h'],ow=t['w'],cout=t['c'],kernel=0,stride=1,activation=0,
            weights=0,bias=0,wlog=t['w'].bit_length()-1,skip_c=t['c'],name=name))
        return dst
    x=conv(0,'encoder.0','encoder_features_0_0_weight','encoder_features_0_1',32,3,2,2)
    skips={};index=1
    for expansion,cout,repeats,stride in ((1,16,1,1),(6,24,2,2),(6,32,3,2),
                                           (6,64,4,2),(6,96,3,1),(6,160,3,2),(6,320,1,1)):
        for repeat in range(repeats):
            original=x; cin=tensors[x]['c'];step=stride if repeat==0 else 1
            prefix=f'encoder_features_{index}_conv'
            hidden=cin*expansion
            if expansion!=1:
                x=conv(x,prefix+'.expand',prefix+'_0_0_weight',prefix+'_0_1',hidden,act=2)
                depth,project,norm=1,2,3
            else:depth,project,norm=0,1,2
            x=conv(x,prefix+'.depthwise',prefix+f'_{depth}_0_weight',prefix+f'_{depth}_1',hidden,3,step,2,True)
            x=conv(x,prefix+'.project',prefix+f'_{project}_weight',prefix+f'_{norm}',cout)
            if step==1 and cin==cout:x=add(original,x,prefix+'.residual')
            if index in (1,3,6,13):skips[index]=x
            index+=1
    x=conv(x,'encoder.18','encoder_features_18_0_weight','encoder_features_18_1',1280,act=2)
    for i,(skip,cout) in enumerate(zip((skips[13],skips[6],skips[3],skips[1],-1),(256,128,64,32,16))):
        t=tensors[x]; sc=tensors[skip]['c'] if skip>=0 else 0
        dst=tensor(f'decoder.{i}.upsample_cat',t['h']*2,t['w']*2,t['c']+sc)
        ops.append(dict(kind=UPSAMPLE_CAT,src=x,skip=skip,dst=dst,ih=t['h'],iw=t['w'],cin=t['c'],
            oh=t['h']*2,ow=t['w']*2,cout=t['c']+sc,kernel=0,stride=1,activation=0,
            weights=0,bias=0,wlog=t['w'].bit_length(),skip_c=sc,name=f'decoder.{i}.upsample_cat'))
        x=dst
        for j in (1,2):
            prefix=f'decoder_blocks_{i}_conv{j}'
            x=conv(x,f'decoder.{i}.conv{j}',prefix+'_0_weight',prefix+'_1',cout,3,act=1)
    logits=conv(x,'segmentation_head','segmentation_head_0_weight',None,5,3)
    ignored={n for n in arrays if n.endswith('_num_batches_tracked')}
    if set(arrays)-used-ignored:raise ValueError('Unused trained parameters: '+str(set(arrays)-used-ignored))
    # Allocate DDR tensors using graph lifetimes. Input survives through output
    # so returned gray is the exact same registered frame, never the next frame.
    last={i:-1 for i in range(len(tensors))}
    for oi,op in enumerate(ops):
        for key in ('src','skip'):
            if op[key]>=0:last[op[key]]=oi
    last[0]=len(ops)+1;last[logits]=len(ops)+1
    free=[];live={};high=0
    def allocate(tid):
        nonlocal high
        t=tensors[tid];size=((t['h']*t['w']*t['c']+15)//16)*16
        fit=next(((i,b) for i,b in enumerate(free) if b[1]>=size),None)
        if fit:
            i,(offset,length)=fit;free.pop(i)
            if length>size:free.append((offset+size,length-size))
        else:offset=high;high+=size
        t['offset']=offset;live[tid]=(offset,size)
    allocate(0)
    for oi,op in enumerate(ops):
        allocate(op['dst'])
        for tid in list(live):
            if last[tid]==oi:free.append(live.pop(tid))
        free.sort();merged=[]
        for offset,length in free:
            if merged and sum(merged[-1])==offset:merged[-1]=(merged[-1][0],merged[-1][1]+length)
            else:merged.append((offset,length))
        free=merged
    label_offset=high;high+=image_size*image_size
    graph=dict(format_version=1,architecture='smp.Unet(mobilenet_v2, in_channels=1, classes=5)',
        lanes=lanes,image_size=image_size,ops=ops,tensors=tensors,logits=logits,
        input=0,workspace_words=high,label_offset=label_offset,weight_words=words,
        used_arrays=len(used),ignored_counters=len(ignored),bn_epsilon=1e-5,
        class_ids=dict(background=0,LA=1,RA=2,LV=3,RV=4),
        class_mapping_verified=False)
    macs=sum(o['oh']*o['ow']*o['cout']*o['kernel']**2*(1 if o['kind']==DEPTHWISE else o['cin'])
             for o in ops if o['kind'] in (CONV,DEPTHWISE))
    graph['macs_per_frame']=macs
    return graph,np.concatenate(blocks).astype('<f4')

def write_export(out,graph,blob,header):
    out.mkdir(parents=True,exist_ok=True);header.parent.mkdir(parents=True,exist_ok=True)
    # Header is committed by the loader LAST. Zero magic keeps PL idle while loading.
    graph['program_id']=zlib.crc32(json.dumps(graph,sort_keys=True).encode())
    blob.view('<u4')[:7]=[0,1,len(graph['ops']),graph['workspace_words'],
                         graph['lanes'],graph['image_size'],graph['program_id']]
    (out/'weights.bin').write_bytes(blob.tobytes())
    graph['weights_sha256']=hashlib.sha256(blob.tobytes()).hexdigest()
    (out/'model.json').write_text(json.dumps(graph,indent=2),encoding='utf-8')
    lines=['// Generated by export_model.py; all offsets are float-word offsets.',
           '#pragma once',f'#define UNET_LANES {graph["lanes"]}',
           f'#define UNET_SIZE {graph["image_size"]}',f'#define UNET_OPS {len(graph["ops"])}',
           f'#define UNET_PROGRAM_ID {graph["program_id"]}u',
           f'#define UNET_WORK_WORDS {graph["workspace_words"]}',
           f'#define UNET_LABEL_OFFSET {graph["label_offset"]}',
           f'#define UNET_LOGITS_OFFSET {graph["tensors"][graph["logits"]]["offset"]}',
           'struct UnetOp { '+ '; '.join('unsigned '+f for f in FIELDS)+'; };',
           'static const UnetOp UNET_PROGRAM[UNET_OPS] = {']
    for op in graph['ops']:
        entry=dict(op)
        for key in ('src','skip','dst'):entry[key]=graph['tensors'][op[key]]['offset'] if op[key]>=0 else 0
        lines.append('    {'+','.join(str(entry[f]) for f in FIELDS)+'}, // '+op['name'])
    lines.append('};')
    header.write_text('\n'.join(lines)+'\n',encoding='ascii')

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path)
    p.add_argument('--out',type=Path,default=ROOT/'build/unet/model')
    p.add_argument('--header',type=Path,default=ROOT/'rtl/unet/hls/model_ops.h')
    p.add_argument('--lanes',type=int,default=16);p.add_argument('--size',type=int,default=256)
    args=p.parse_args()
    source=args.source or next((ROOT/'ip/ai4chamberseger').glob('*.zip'))
    arrays=read_float_weights(source);graph,blob=build_graph(arrays,args.lanes,args.size)
    write_export(args.out,graph,blob,args.header)
    print(json.dumps({k:graph[k] for k in ('architecture','used_arrays','ignored_counters','weight_words','workspace_words','macs_per_frame')}))
    print('MODEL_EXPORT_OK ops='+str(len(graph['ops'])))

if __name__=='__main__':main()
