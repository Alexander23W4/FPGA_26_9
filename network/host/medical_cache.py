"""Patient-local semantic segmentation cache. Disk IO has a dedicated worker."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import threading
import numpy as np
from PIL import Image

PIXELS = 256 * 256
CACHE_DIR = '.heartcare_unet'
COLORS = np.array([[191,63,101], [255,212,0], [0,210,96], [40,120,255]], dtype=np.uint8)
# PL uses red/yellow/green/blue in LA/RA/LV/RV order.
COLORS[0] = [255,0,0]

def sha(data):
    return hashlib.sha256(data).hexdigest()

def semantic_planes(raw):
    if len(raw) != PIXELS*4:
        raise ValueError('semantic result must have 65536 four-byte pixels')
    a = np.frombuffer(raw, dtype=np.uint8).reshape(PIXELS,4)
    if not np.all(a[:,3] == 255):
        raise ValueError('semantic result alpha is invalid')
    mask, contour = a[:,1], a[:,2]
    if not np.isin(mask, [0,1,2,4,8]).all() or np.any(contour & ~mask):
        raise ValueError('semantic result contains invalid chamber flags')
    return a[:,0].tobytes(), mask.tobytes(), contour.tobytes()

def packed_input(gray, mask, contour=None):
    if len(gray) != PIXELS or len(mask) != PIXELS or (contour is not None and len(contour) != PIXELS):
        raise ValueError('cached planes must be 256x256')
    a=np.zeros((PIXELS,3), dtype=np.uint8)
    a[:,0]=np.frombuffer(gray,dtype=np.uint8);a[:,1]=np.frombuffer(mask,dtype=np.uint8)
    if contour is not None:a[:,2]=np.frombuffer(contour,dtype=np.uint8)
    return a.tobytes()

def preview_rgba(raw, mode, alpha=45):
    gray, mask, contour=semantic_planes(raw)
    g=np.frombuffer(gray,dtype=np.uint8);flags=np.frombuffer(mask if mode==3 else contour,dtype=np.uint8)
    rgb=np.repeat(g[:,None],3,axis=1)
    for i,color in reversed(list(enumerate(COLORS))):
        hit=(flags & (1<<i)) != 0
        rgb[hit]=((rgb[hit].astype(np.uint16)*(100-alpha)+color.astype(np.uint16)*alpha)//100).astype(np.uint8) if mode==3 else color
    rgba=np.empty((PIXELS,4),dtype=np.uint8);rgba[:,:3]=rgb;rgba[:,3]=255
    return rgba.tobytes()

class PatientCache:
    def __init__(self, patient, sources, model_key):
        self.patient=Path(patient).resolve();self.directory=self.patient/CACHE_DIR
        self.model_key=str(model_key);self.sources={}
        for path in sources:
            path=Path(path).resolve();name=path.relative_to(self.patient).as_posix()
            if CACHE_DIR in Path(name).parts or not name.lower().endswith('.bin') or path.stat().st_size!=PIXELS:
                raise ValueError('invalid original patient frame')
            self.sources[name]=path
        if not self.sources:raise ValueError('patient has no source frames')
        self._executor=ThreadPoolExecutor(max_workers=1,thread_name_prefix='medical-cache-save')
        self._pending=[];self._lock=threading.Lock();self._closed=False

    def _paths(self,name):
        if name not in self.sources:raise ValueError('frame does not belong to selected patient')
        base=self.directory/'frames'/Path(name)
        return {kind:base.with_name(base.name+'.'+kind+suffix) for kind,suffix in
                [('gray','.bin'),('mask','.bin'),('contour','.bin'),('mask_preview','.png'),('contour_preview','.png'),('record','.json')]}

    @staticmethod
    def _atomic(path,data):
        path.parent.mkdir(parents=True,exist_ok=True)
        temporary=path.with_name(path.name+'.pending')
        with temporary.open('wb') as f:
            f.write(data);f.flush()
        os.replace(temporary,path)

    def _write(self,name,source_hash,raw):
        gray,mask,contour=semantic_planes(raw);paths=self._paths(name)
        planes={'gray':gray,'mask':mask,'contour':contour}
        # Invalidate the old commit before replacing any of its data files.
        paths['record'].unlink(missing_ok=True)
        for kind,data in planes.items():self._atomic(paths[kind],data)
        for kind,flags in [('mask_preview',mask),('contour_preview',contour)]:
            image=np.zeros((PIXELS,3),dtype=np.uint8);a=np.frombuffer(flags,dtype=np.uint8)
            for i,color in reversed(list(enumerate(COLORS))):image[(a&(1<<i))!=0]=color
            import io
            stream=io.BytesIO();Image.fromarray(image.reshape(256,256,3)).save(stream,format='PNG')
            self._atomic(paths[kind],stream.getvalue())
        record={'version':1,'model':self.model_key,'source':name,'source_sha256':source_hash,
                'planes':{kind:sha(data) for kind,data in planes.items()}}
        # This record is the commit: neither presence nor an old filename is completion.
        self._atomic(paths['record'],json.dumps(record,ensure_ascii=False).encode('utf-8'))

    def save_async(self,name,source,raw):
        semantic_planes(raw)
        if name not in self.sources or len(source)!=PIXELS:raise ValueError('invalid cache source')
        with self._lock:
            if self._closed:raise RuntimeError('cache saver closed')
            keep=[]
            for future in self._pending:
                if future.done():future.result()
                else:keep.append(future)
            if len(keep)>=4:raise OSError('patient cache disk writer has four unsaved frames; check the disk')
            future=self._executor.submit(self._write,name,sha(source),bytes(raw))
            self._pending=keep+[future]
            return future

    def read(self,name,source=None):
        paths=self._paths(name);record=json.loads(paths['record'].read_text(encoding='utf-8'))
        if record.get('version')!=1 or record.get('model')!=self.model_key or record.get('source')!=name:
            raise ValueError('cache belongs to another model or format')
        original=self.sources[name].read_bytes() if source is None else source
        if len(original)!=PIXELS or sha(original)!=record.get('source_sha256'):
            raise ValueError('original frame changed after segmentation')
        planes={kind:paths[kind].read_bytes() for kind in ('gray','mask','contour')}
        for kind,data in planes.items():
            if len(data)!=PIXELS or sha(data)!=record.get('planes',{}).get(kind):raise ValueError('cached '+kind+' is incomplete or changed')
        if not all(paths[k].is_file() for k in ('mask_preview','contour_preview')):raise ValueError('cached previews are incomplete')
        return planes

    def status(self):
        completed=0
        for name in self.sources:
            try:self.read(name);completed+=1
            except (OSError,ValueError,KeyError):pass
        with self._lock:
            errors=[str(f.exception()) for f in self._pending if f.done() and f.exception() is not None]
        return {'complete':completed==len(self.sources),'completed':completed,'total':len(self.sources),
                'saving':sum(not f.done() for f in self._pending),'error':errors[0] if errors else None,
                'label':'已完成模型分割' if completed==len(self.sources) else '未完成模型分割'}

    def close(self):
        with self._lock:self._closed=True
        self._executor.shutdown(wait=True)
        for future in self._pending:future.result()
