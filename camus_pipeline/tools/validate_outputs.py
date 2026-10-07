#!/usr/bin/env python3
import csv,json,re,sys
from pathlib import Path
import numpy as np
from PIL import Image

def read_coe(p):
 text=p.read_text(encoding='ascii')
 m=re.search(r'memory_initialization_vector\s*=(.*)',text,re.S)
 if not m: raise ValueError('missing vector')
 vals=re.findall(r'\b[0-9A-Fa-f]{1,2}\b',m.group(1))
 return np.array([int(x,16) for x in vals],dtype=np.uint8)

def sha(p):
 import hashlib
 h=hashlib.sha256(); f=open(p,'rb')
 for b in iter(lambda:f.read(1048576),b''): h.update(b)
 f.close(); return h.hexdigest()

def main():
 root=Path(sys.argv[1]) if len(sys.argv)>1 else Path(r'C:/Users/13995/Desktop/fpga校赛/camus_processed')
 manifest=root/'manifest.csv'; errors=[]; checked=0
 with manifest.open(encoding='utf-8-sig',newline='') as f:
  for r in csv.DictReader(f):
   if r.get('status')!='converted': continue
   try:
    png=np.asarray(Image.open(r['image_png']))
    b=np.fromfile(r['image_bin'],dtype=np.uint8)
    c=read_coe(Path(r['image_coe']))
    gl=np.fromfile(r['gt_label_bin'],dtype=np.uint8)
    gm=np.fromfile(r['gt_mask_bin'],dtype=np.uint8)
    if png.shape!=(256,256): errors.append((r['patient'],r['case'],'png shape'))
    if b.size!=65536 or c.size!=65536: errors.append((r['patient'],r['case'],'bin/coe size'))
    if not np.array_equal(png.reshape(-1),b): errors.append((r['patient'],r['case'],'png != bin'))
    if not np.array_equal(b,c): errors.append((r['patient'],r['case'],'coe != bin'))
    if gl.size!=65536 or gm.size!=65536: errors.append((r['patient'],r['case'],'gt size'))
    if not set(map(int,np.unique(gl))).issubset({0,1,2,3}): errors.append((r['patient'],r['case'],'gt labels'))
    if not set(map(int,np.unique(gm))).issubset({0,1}): errors.append((r['patient'],r['case'],'mask values'))
    j=json.loads(Path(r['metadata']).read_text(encoding='utf-8'))
    for key,rel in j['sha256'].items():
     op=Path(j['outputs'][key])
     if sha(op)!=rel: errors.append((r['patient'],r['case'],'sha '+key))
    checked+=1
   except Exception as e: errors.append((r.get('patient'),r.get('case'),repr(e)))
 print(json.dumps({'manifest':str(manifest),'checked':checked,'errors':len(errors),'error_sample':errors[:20]},ensure_ascii=False,indent=2))
 return 1 if errors else 0
if __name__=='__main__': raise SystemExit(main())
