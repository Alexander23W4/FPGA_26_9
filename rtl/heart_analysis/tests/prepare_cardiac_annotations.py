from pathlib import Path
import sys,json,math,argparse
import numpy as np
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'camus_pipeline/tools'))
from convert_camus import read_nii,fit
CLASSES=(2,3,1,4)

def fill_boundary(mask):
 ys,xs=np.where(mask)
 if not len(xs):return np.zeros_like(mask)
 y0,y1=int(ys.min()),int(ys.max())+1;x0,x1=int(xs.min()),int(xs.max())+1
 crop=np.pad(mask[y0:y1,x0:x1],1).astype(np.uint8)*255
 im=Image.fromarray(crop).copy()
 ImageDraw.floodfill(im,(0,0),128)
 assert im.getpixel((0,0))==128
 result=np.zeros_like(mask)
 result[y0:y1,x0:x1]=(np.asarray(im)!=128)[1:-1,1:-1]
 return result

def disc_sum(mask):
 has=mask.any(axis=1)
 first=np.argmax(mask,axis=1)
 last=mask.shape[1]-1-np.argmax(mask[:,::-1],axis=1)
 widths=np.where(has,last-first+1,0).astype(np.int64)
 return int(widths@widths)

def aligned_proxy(mask):
 ys,xs=np.where(mask)
 if not len(xs):return 0.,0.,0.
 xy=np.column_stack((xs,ys)).astype(float);xy-=xy.mean(axis=0)
 _,vec=np.linalg.eigh(xy.T@xy)
 axis=vec[:,-1];angle=math.degrees(math.atan2(axis[1],axis[0]))-90
 if angle>90:angle-=180
 if angle< -90:angle+=180
 rot=np.asarray(Image.fromarray(mask.astype(np.uint8)*255).rotate(angle,resample=Image.Resampling.NEAREST,expand=True))>0
 length=float(np.ptp(xy@axis)+1)
 a=int(mask.sum())
 return math.pi/4*disc_sum(rot),8*a*a/(3*math.pi*length),angle

def prepare(DATA,OUT,pixel_case='normal-23-4'):
 OUT.mkdir(parents=True,exist_ok=True)
 records=[]
 for lp in sorted(DATA.glob('*_label.nii.gz')):
  name=lp.name.removesuffix('_label.nii.gz')
  raw,meta=read_nii(lp);labels=sorted(map(int,np.unique(raw)))
  rec={'name':name,'source_label':str(lp),'labels':labels,'frames':int(raw.shape[2])}
  if labels!=[0,1,2,3,4]:
   rec['excluded']='Non-canonical labels: semantic remapping requires review.';records.append(rec)
   print(name,'EXCLUDED',labels,flush=True);continue
  out=OUT/name;out.mkdir(exist_ok=True)
  t=raw.shape[2];bits=np.zeros((t,256,256),np.uint8);vol=np.zeros((t,4),np.uint32)
  area=np.zeros((t,4),np.int64);native_area=np.zeros((t,4),np.int64);stroke=np.zeros((t,4),np.int64)
  aligned=np.zeros(t);arealen=np.zeros(t);angle=np.zeros(t);warnings=[]
  for f in range(t):
   label=raw[:,:,f].T[::-1,:]
   for c,cls in enumerate(CLASSES):
    boundary=label==cls;filled=fill_boundary(boundary)
    stroke[f,c]=boundary.sum();native_area[f,c]=filled.sum()
    if boundary.sum() and filled.sum()<2*boundary.sum():warnings.append([f,cls,'little_or_no_enclosed_region'])
    square,_=fit(filled.astype(np.uint8),(256,256),nearest=True);mask=square>0
    bits[f]|=mask.astype(np.uint8)<<c;area[f,c]=mask.sum()
    s=disc_sum(mask);vol[f,c]=(s*5147185+32768)>>16
    if cls==1:aligned[f],arealen[f],angle[f]=aligned_proxy(mask)
  np.savez_compressed(out/'masks_and_reference.npz',masks=bits,volumes_x100=vol,areas=area,
                      native_areas=native_area,stroke_pixels=stroke,pca_volume=aligned,
                      area_length_volume=arealen,pca_angle=angle)
  (out/'volumes.hex').write_text(''.join(''.join(f'{int(v):08x}' for v in row[::-1])+'\n' for row in vol),encoding='ascii')
  lut=np.array([f'{i:x}\n'.encode('ascii') for i in range(16)],dtype='S2')
  if name==pixel_case:
   frame_dir=out/'mask_frames';frame_dir.mkdir(exist_ok=True)
   for index,frame in enumerate(bits):
    (frame_dir/f'frame_{index:03d}.hex').write_bytes(lut[frame.reshape(-1)].tobytes())
  rec.update({'accepted':True,'out':str(out),'fill_warnings':warnings,
              'lv_area_range':list(map(int,[area[:,2].min(),area[:,2].max()])),
              'lv_volume_range_px3':[float(vol[:,2].min()/100),float(vol[:,2].max()/100)]})
  records.append(rec)
  print(name,'frames',t,'LV area range',rec['lv_area_range'],'LV volume range',rec['lv_volume_range_px3'],'fill warnings',len(warnings),flush=True)
  (OUT/'cases.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
 (OUT/'cases.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
 print('PREPARED',sum(r.get('accepted',False) for r in records),'cases',flush=True)
 return records

if __name__=='__main__':
 parser=argparse.ArgumentParser(description='Read-only CardiacUDA contour-to-mask geometry preparation; no clinical truth is inferred.')
 parser.add_argument('--data',type=Path,required=True,help='label_all_frame directory')
 parser.add_argument('--out',type=Path,required=True)
 parser.add_argument('--pixel-case',default='normal-23-4')
 args=parser.parse_args()
 if not args.data.is_dir():parser.error('data directory does not exist')
 prepare(args.data.resolve(),args.out.resolve(),args.pixel_case)
