"""Run full-model arithmetic comparisons and independently check output geometry."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import numpy as np

ROOT=Path(__file__).resolve().parents[3]
def check(out,frame):
    a=np.fromfile(out/'hardware_algorithm.logits',dtype='<f4').reshape(256,256,5)
    b=np.fromfile(out/'numpy_reference.logits',dtype='<f4').reshape(a.shape)
    pixels=np.fromfile(out/'hardware_algorithm.pixels',dtype='<u2').reshape(256,256)
    raw=np.fromfile(frame,dtype='u1').reshape(256,256)
    labels=a.argmax(-1);other=b.argmax(-1)
    assert np.allclose(a,b,rtol=2e-3,atol=3e-3),'full-network logits mismatch'
    assert np.array_equal(labels,other),'different segmentation labels'
    assert np.array_equal(pixels&255,raw),'original registered gray not preserved'
    masks=np.where(labels>0,1<<np.maximum(labels-1,0),0).astype(np.uint16)
    padded=np.pad(labels,1)
    edge=(padded[:-2,1:-1]!=labels)|(padded[2:,1:-1]!=labels)|\
         (padded[1:-1,:-2]!=labels)|(padded[1:-1,2:]!=labels)
    contours=masks*edge
    assert np.array_equal((pixels>>8)&15,masks),'chamber mask mismatch'
    assert np.array_equal((pixels>>12)&15,contours),'2D chamber contour mismatch'
    report=dict(max_logit_error=float(np.max(np.abs(a-b))),mean_logit_error=float(np.mean(np.abs(a-b))),
        label_mismatches=int(np.count_nonzero(labels!=other)),pixels=65536,
        class_histogram=np.bincount(labels.ravel(),minlength=5).tolist(),
        input_sha256=hashlib.sha256(frame.read_bytes()).hexdigest())
    (out/'verification.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('COMPLETE_UNET_VERIFIED',json.dumps(report))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'build/unet')
    p.add_argument('--frame',type=Path);p.add_argument('--compiler',type=Path,
        default=Path('E:/Xilinx/Vivado/2023.2/tps/mingw/9.3.0/win64.o/nt/bin/g++.exe'))
    args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    frame=args.frame or out/'input.bin'
    subprocess.run([str(args.compiler),'-std=c++14','-O3','-fno-strict-aliasing','-ffp-contract=off',
        '-static','-Wno-unknown-pragmas',str(ROOT/'rtl/unet/tests/host_test.cpp'),'-o',str(out/'host_static.exe')],check=True)
    subprocess.run([str(out/'host_static.exe'),str(ROOT/'build/unet/model/weights.bin'),str(frame),str(out/'hardware_algorithm')],check=True)
    import sys
    subprocess.run([sys.executable,str(ROOT/'rtl/unet/tools/reference.py'),str(ROOT/'build/unet/model'),str(frame),str(out/'numpy_reference'),'--unfolded'],check=True)
    check(out,frame)
