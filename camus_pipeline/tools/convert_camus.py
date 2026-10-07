#!/usr/bin/env python3
import argparse,csv,gzip,hashlib,json,math,struct
from pathlib import Path
import numpy as np
from PIL import Image
DT={2:'u1',4:'i2',8:'i4',16:'f4',64:'f8',256:'i1',512:'u2',768:'u4',1024:'i8',1280:'u8'}
UNITS={0:'unknown',1:'meter',2:'mm',3:'micron'}
CASES=('2CH_ED','2CH_ES','4CH_ED','4CH_ES')
def sha(p):
 h=hashlib.sha256(); f=open(p,'rb')
 for b in iter(lambda:f.read(1048576),b''): h.update(b)
 f.close(); return h.hexdigest()
def read_nii(p):
 raw=gzip.open(p,'rb').read()
 if len(raw)<352: raise ValueError('too small '+str(p))
 if struct.unpack('<i',raw[:4])[0]==348: e='<'
 elif struct.unpack('>i',raw[:4])[0]==348: e='>'
 else: raise ValueError('not nifti '+str(p))
 dim=struct.unpack(e+'8h',raw[40:56]); dt=struct.unpack(e+'h',raw[70:72])[0]; bp=struct.unpack(e+'h',raw[72:74])[0]
 pix=struct.unpack(e+'8f',raw[76:108]); off=int(round(struct.unpack(e+'f',raw[108:112])[0])); slope,inter=struct.unpack(e+'2f',raw[112:120])
 qc=struct.unpack(e+'h',raw[252:254])[0]; sc=struct.unpack(e+'h',raw[254:256])[0]; units=raw[123]
 nd=int(dim[0]); shape=tuple(int(x) for x in dim[1:nd+1]); code=DT.get(int(dt))
 if not 1<=nd<=7 or any(x<=0 for x in shape) or code is None: raise ValueError('unsupported nifti '+str(p))
 a=np.frombuffer(raw,dtype=np.dtype(e+code),count=int(np.prod(shape)),offset=off).reshape(shape,order='F')
 if slope!=0 and (slope!=1 or inter!=0): a=a.astype(np.float32)*slope+inter
 else: a=np.array(a,copy=True)
 m={'source_file':str(p),'shape':list(shape),'dtype':str(a.dtype),'datatype_code':int(dt),'bitpix':int(bp),'vox_offset':off,'pixdim':list(map(float,pix)),'spacing':list(map(float,pix[1:nd+1])),'spatial_units':UNITS.get(int(units&7),'unknown'),'qform_code':int(qc),'sform_code':int(sc),'scl_slope':float(slope),'scl_inter':float(inter),'data_min':float(np.nanmin(a)),'data_max':float(np.nanmax(a))}
 return a,m
def splits(d):
 out={}
 for split,name in (('training','subgroup_training.txt'),('validation','subgroup_validation.txt'),('testing','subgroup_testing.txt')):
  for line in (d/name).read_text(encoding='utf-8').splitlines():
   p=line.strip()
   if p: out[p]=split
 return out
def norm(a,lo,hi):
 x=np.asarray(a,dtype=np.float32); v=x[np.isfinite(x)]
 if not len(v): raise ValueError('no finite pixels')
 pl=float(np.percentile(v,lo)); ph=float(np.percentile(v,hi))
 if not math.isfinite(pl) or not math.isfinite(ph) or ph<=pl: pl=float(v.min()); ph=float(v.max())
 y=np.zeros(x.shape,dtype=np.uint8) if ph<=pl else np.rint(np.clip((np.nan_to_num(x,nan=pl,posinf=ph,neginf=pl)-pl)*255.0/(ph-pl),0,255)).astype(np.uint8)
 return y,{'method':'percentile','percentile_low':lo,'percentile_high':hi,'clip_low':pl,'clip_high':ph,'source_min':float(v.min()),'source_max':float(v.max()),'output_dtype':'uint8','output_range':[0,255]}
def fit(a,size,nearest=False):
 h,w=a.shape[:2]; ow,oh=size; sc=min(ow/w,oh/h); nw=max(1,round(w*sc)); nh=max(1,round(h*sc))
 r=Image.Resampling.NEAREST if nearest else Image.Resampling.LANCZOS
 b=np.asarray(Image.fromarray(a).resize((nw,nh),r)); x0=(ow-nw)//2; y0=(oh-nh)//2; c=np.zeros((oh,ow),a.dtype); c[y0:y0+nh,x0:x0+nw]=b
 return c,{'method':'letterbox','scale':float(sc),'resized_size':[nw,nh],'padding_xy':[x0,y0],'valid_bbox_xywh':[x0,y0,nw,nh],'interpolation':'nearest' if nearest else 'lanczos'}
def coe(p,a):
 d=np.asarray(a,dtype=np.uint8).ravel(); q=['memory_initialization_radix=16;','memory_initialization_vector=']
 for i in range(0,d.size,16): q.append(','.join(f'{int(x):02X}' for x in d[i:i+16])+(';' if i+16>=d.size else ','))
 p.write_text('\n'.join(q)+'\n',encoding='ascii')
def png(p,a): Image.fromarray(np.asarray(a,dtype=np.uint8),mode='L').save(p)
def one(patient,case,split,src,out,lo,hi,size,overwrite):
 c=src/patient; ip=c/f'{patient}_{case}.nii.gz'; gp=c/f'{patient}_{case}_gt.nii.gz'; id=out/'images'/split/patient; md=out/'masks'/split/patient; jd=out/'metadata'/split/patient
 for d in (id,md,jd): d.mkdir(parents=True,exist_ok=True)
 stem=f'{patient}_{case}'; paths={'png':id/f'{stem}.png','bin':id/f'{stem}.bin','coe':id/f'{stem}.coe','gtpng':md/f'{stem}_gt_label.png','gtbin':md/f'{stem}_gt_label.bin','maskpng':md/f'{stem}_gt_mask.png','maskbin':md/f'{stem}_gt_mask.bin','json':jd/f'{stem}.json'}
 if not overwrite and all(x.exists() for x in paths.values()): return {'status':'skipped','patient':patient,'case':case,'split':split,'image_png':str(paths['png']),'image_bin':str(paths['bin']),'image_coe':str(paths['coe']),'gt_label_bin':str(paths['gtbin']),'gt_mask_bin':str(paths['maskbin']),'metadata':str(paths['json'])}
 ai,mi=read_nii(ip); ag,mg=read_nii(gp)
 if ai.shape!=ag.shape: raise ValueError('shape mismatch '+stem)
 i8,nm=norm(ai,lo,hi); i256,tr=fit(i8,size,False); g=np.rint(ag).astype(np.int16)
 if not set(map(int,np.unique(g))).issubset({0,1,2,3}): raise ValueError('bad labels '+stem)
 g256,gt=fit(g,size,True); m=(g256>0).astype(np.uint8)
 png(paths['png'],i256); paths['bin'].write_bytes(i256.tobytes()); coe(paths['coe'],i256); png(paths['gtpng'],g256.astype(np.uint8)); paths['gtbin'].write_bytes(g256.astype(np.uint8).tobytes()); png(paths['maskpng'],m*255); paths['maskbin'].write_bytes(m.tobytes())
 sp=mi['spacing']; eff=[sp[0]/tr['scale'],sp[1]/tr['scale']] if len(sp)>=2 else None
 j={'dataset':'CAMUS_public','patient':patient,'case':case,'split':split,'source_image':str(ip),'source_gt':str(gp),'input_image_meta':mi,'input_gt_meta':mg,'normalization':nm,'transform':tr,'gt_transform':gt,'effective_spacing_after_letterbox':eff,'outputs':{k:str(v) for k,v in paths.items()},'sha256':{k:sha(v) for k,v in paths.items() if k not in ('json',)},'notes':['CAMUS is echocardiography, not CT; use for engineering validation only.','Letterbox scaling avoids geometric distortion.']}
 paths['json'].write_text(json.dumps(j,ensure_ascii=False,indent=2),encoding='utf-8')
 return {'status':'converted','patient':patient,'case':case,'split':split,'source_shape':'x'.join(map(str,ai.shape)),'output_shape':'256x256','valid_bbox_xywh':' '.join(map(str,tr['valid_bbox_xywh'])),'image_png':str(paths['png']),'image_bin':str(paths['bin']),'image_coe':str(paths['coe']),'gt_label_bin':str(paths['gtbin']),'gt_mask_bin':str(paths['maskbin']),'metadata':str(paths['json']),'sha256_image_bin':j['sha256']['bin']}
def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--input',type=Path,default=Path(r'C:/Users/13995/Desktop/fpga校赛/CAMUS_public')); ap.add_argument('--output',type=Path,default=Path(r'C:/Users/13995/Desktop/fpga校赛/camus_processed')); ap.add_argument('--size',type=int,nargs=2,default=(256,256)); ap.add_argument('--percentile',type=float,nargs=2,default=(1.0,99.0)); ap.add_argument('--patients',default=''); ap.add_argument('--limit',type=int,default=0); ap.add_argument('--overwrite',action='store_true'); a=ap.parse_args()
 src=a.input.resolve(); out=a.output.resolve(); nd=src/'database_nifti'; sd=src/'database_split'; sm=splits(sd); ps=sorted(p.name for p in nd.iterdir() if p.is_dir() and p.name.startswith('patient'))
 sel=[x.strip() for x in a.patients.split(',') if x.strip()] if a.patients.strip() else ps
 if a.limit: sel=sel[:a.limit]
 miss=[p for p in sel if p not in sm]
 if miss: raise SystemExit('missing split: '+','.join(miss[:10]))
 rows=[]; total=len(sel)*len(CASES); n=0
 for p in sel:
  for c in CASES:
   n+=1
   try: r=one(p,c,sm[p],nd,out,a.percentile[0],a.percentile[1],tuple(a.size),a.overwrite)
   except Exception as e: r={'status':'error','patient':p,'case':c,'split':sm[p],'error':repr(e)}
   rows.append(r)
   if n%25==0 or n==total: print(f'[{n}/{total}] {p} {c} {r["status"]}',flush=True)
 out.mkdir(parents=True,exist_ok=True); mp=out/'manifest.csv'; fields=['status','patient','case','split','source_shape','output_shape','valid_bbox_xywh','image_png','image_bin','image_coe','gt_label_bin','gt_mask_bin','metadata','sha256_image_bin','error']
 with mp.open('w',newline='',encoding='utf-8-sig') as f:
  w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore'); w.writeheader(); w.writerows(rows)
 print(json.dumps({'output':str(out),'manifest':str(mp),'total':total,'converted':sum(r['status']=='converted' for r in rows),'skipped':sum(r['status']=='skipped' for r in rows),'errors':sum(r['status']=='error' for r in rows)},ensure_ascii=False,indent=2)); return 1 if any(r['status']=='error' for r in rows) else 0
if __name__=='__main__': raise SystemExit(main())
