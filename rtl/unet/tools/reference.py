"""Independent NumPy tensor interpreter for the complete exported graph."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','4')
import argparse
import json
from pathlib import Path
import time
import numpy as np

def source_keys(name):
    if name=='encoder.0':return 'encoder_features_0_0_weight','encoder_features_0_1'
    if name=='encoder.18':return 'encoder_features_18_0_weight','encoder_features_18_1'
    if name=='segmentation_head':return 'segmentation_head_0_weight',None
    if name.startswith('decoder.'):
        _,block,conv=name.split('.');prefix=f'decoder_blocks_{block}_{conv}'
        return prefix+'_0_weight',prefix+'_1'
    prefix,kind=name.split('.')
    first=prefix=='encoder_features_1_conv'
    if kind=='expand':return prefix+'_0_0_weight',prefix+'_0_1'
    if kind=='depthwise':
        index=0 if first else 1
        return prefix+f'_{index}_0_weight',prefix+f'_{index}_1'
    return prefix+f'_{1 if first else 2}_weight',prefix+f'_{2 if first else 3}'

def run(model_dir,frame,output,unfolded=False):
    graph=json.loads((model_dir/'model.json').read_text(encoding='utf-8'))
    blob=np.fromfile(model_dir/'weights.bin',dtype='<f4');lanes=graph['lanes']
    arrays=None
    if unfolded:
        from export_model import read_float_weights,ROOT
        arrays=read_float_weights(next((ROOT/'ip/ai4chamberseger').glob('*.zip')))
    n=graph['image_size'];raw=np.fromfile(frame,dtype=np.uint8)
    if raw.size!=n*n:raise ValueError('Wrong input frame size')
    values={0:raw.reshape(n,n,1).astype(np.float32)/np.float32(255)}
    refs={i:0 for i in range(len(graph['tensors']))}
    for op in graph['ops']:
        for key in ('src','skip'):
            if op[key]>=0:refs[op[key]]+=1
    start=time.perf_counter()
    for oi,op in enumerate(graph['ops']):
        x=values[op['src']];kind=op['kind']
        if kind in (0,1):
            co=op['cout'];ci=op['cin'];k=op['kernel'];red=1 if kind==1 else ci
            padded=((co+lanes-1)//lanes)*lanes;count=padded*k*k*red
            w=blob[op['weights']:op['weights']+count].reshape(-1,k,k,red,lanes)
            w=w.transpose(0,4,1,2,3).reshape(padded,k,k,red)[:co]
            b=blob[op['bias']:op['bias']+co]
            bn=None
            if arrays is not None:
                weight_key,bn=source_keys(op['name'])
                w=arrays[weight_key].reshape(co,red,k,k).transpose(0,2,3,1)
                b=np.zeros(co,np.float32) if bn else arrays[weight_key.removesuffix('_weight')+'_bias']
            pad=k//2
            xp=np.pad(x,((pad,pad),(pad,pad),(0,0)))
            patches=np.lib.stride_tricks.sliding_window_view(xp,(k,k),axis=(0,1))[::op['stride'],::op['stride']]
            if kind==1:
                y=np.einsum('hwcij,cij->hwc',patches,w[:,:,:,0],optimize=True)+b
            else:
                matrix=patches.transpose(0,1,3,4,2).reshape(-1,k*k*ci)
                y=(matrix@w.reshape(co,-1).T+b).reshape(op['oh'],op['ow'],co)
            if bn:
                y=(y-arrays[bn+'_running_mean'])/np.sqrt(arrays[bn+'_running_var']+np.float32(1e-5))
                y=y*arrays[bn+'_weight']+arrays[bn+'_bias']
            if op['activation']:y=np.maximum(y,0)
            if op['activation']==2:y=np.minimum(y,6)
        elif kind==2:y=x+values[op['skip']]
        else:
            y=x.repeat(2,axis=0).repeat(2,axis=1)
            if op['skip']>=0:y=np.concatenate((y,values[op['skip']]),axis=2)
        if not np.isfinite(y).all():raise ValueError('Nonfinite layer '+op['name'])
        values[op['dst']]=y.astype(np.float32)
        for key in ('src','skip'):
            tid=op[key]
            if tid>=0:
                refs[tid]-=1
                if refs[tid]==0:values.pop(tid,None)
        print(f'{oi+1:02d}/{len(graph["ops"])} {op["name"]} {y.shape}',flush=True)
    logits=values[graph['logits']];labels=logits.argmax(axis=2).astype(np.uint8)
    output.parent.mkdir(parents=True,exist_ok=True)
    logits.astype('<f4').tofile(str(output)+'.logits');labels.tofile(str(output)+'.labels')
    print('NUMPY_REFERENCE_OK seconds=%.3f histogram=%s'%(time.perf_counter()-start,np.bincount(labels.ravel(),minlength=5).tolist()))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('model',type=Path);p.add_argument('frame',type=Path);p.add_argument('out',type=Path)
    p.add_argument('--unfolded',action='store_true')
    a=p.parse_args();run(a.model,a.frame,a.out,a.unfolded)
