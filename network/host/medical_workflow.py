"""Two medical workflows sharing the existing full-duplex frame transport."""
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
import hashlib
from pathlib import Path
import re
import numpy as np
from medical_cache import PatientCache,packed_input,semantic_planes,preview_rgba

@lru_cache(maxsize=8)
def _model_key(inputs, class_map):
    digest=hashlib.sha256()
    digest.update(b'patient-cache-v3\0')
    digest.update(class_map.encode('ascii'))
    for name,filename,size,mtime_ns,ctime_ns in inputs:
        encoded=name.encode('utf-8')
        digest.update(len(encoded).to_bytes(4,'little'));digest.update(encoded)
        digest.update(size.to_bytes(8,'little'))
        content=Path(filename).read_bytes()
        digest.update(len(content).to_bytes(8,'little'));digest.update(content)
    return digest.hexdigest()

def legacy_model_key(repo):
    """Accept existing commits made with the previous timestamp-based key."""
    return _legacy_key(_model_inputs(repo))

@lru_cache(maxsize=8)
def _legacy_key(config):
    inputs,class_map=config;digest=hashlib.sha256()
    digest.update(b'patient-cache-v3\0');digest.update(class_map.encode('ascii'))
    for name,filename,size,mtime_ns,ctime_ns in inputs:
        encoded=name.encode('utf-8');digest.update(len(encoded).to_bytes(4,'little'));digest.update(encoded)
        digest.update(size.to_bytes(8,'little'));digest.update(mtime_ns.to_bytes(8,'little',signed=True))
        digest.update(ctime_ns.to_bytes(8,'little',signed=True))
        content=Path(filename).read_bytes();digest.update(len(content).to_bytes(8,'little'));digest.update(content)
    return digest.hexdigest()

def _model_inputs(repo):
    root=Path(repo).resolve()
    source=next((root/'ip/ai4chamberseger').glob('*.zip'))
    paths=[source,
           root/'rtl/unet/hls/unet_ddr_core.cpp',
           root/'rtl/unet/hls/unet_ddr_core.h',
           root/'rtl/unet/hls/unet_conv.h',
           root/'rtl/unet/hls/model_ops.h',
           root/'rtl/unet/unet.v',
           root/'rtl/unet/unet_stream_cdc.v',
           root/'rtl/unet/unet_status_cdc.v',
           root/'rtl/unet/generated/source_fingerprint.json',
           root/'rtl/inter_fr/ddr/registration_ddr.cpp',
           root/'rtl/inter_fr/ddr/registration_ddr_top.v',
           root/'rtl/inter_fr/ddr/generated/source_fingerprint.json',
           root/'rtl/heart_analysis/mask_to_contour.v',
           root/'rtl/medical_cache_input.v',
           root/'rtl/top1.v']
    config=root/'rtl/unet/model_config.json'
    if config.is_file():
        paths.append(config)
        import json
        if json.loads(config.read_text())['backend']=='small-int8':
            paths.extend(root/'rtl/unet/small_hls'/name for name in ('small_unet.cpp','model_layout_small.h','model_load.tcl'))
            paths.append(root/'rtl/unet/small_generated/source_fingerprint.json')
    # The loaded DDR image is the final authority for the exact deployed weights.
    deployed=root/'build/unet/model/weights.bin'
    if deployed.is_file():paths.append(deployed)
    inputs=tuple((path.relative_to(root).as_posix(),str(path),path.stat().st_size,
                  path.stat().st_mtime_ns,path.stat().st_ctime_ns)
                 for path in paths)
    top=(root/'rtl/top1.v').read_text(encoding='utf-8')
    class_map=re.search(r"UNET_CLASS_MAP\s*=\s*16'h([0-9a-fA-F]+)",top).group(1)
    return inputs,class_map

def model_key(repo):
    return _model_key(*_model_inputs(repo))

def register_to_reference(reference, image):
    """Exact integer ROI/SAD and shift used by registration_ddr.cpp.

    A resumed job cannot replay cached frames through U-Net just to restore the
    PL's volatile first-frame reference. Align only missing frames here, then
    mark each as a fresh PL reference so the PL registration preserves it.
    """
    ref=np.frombuffer(reference,dtype=np.uint8).reshape(256,256)[104:152,104:152].astype(np.int16)
    current=np.frombuffer(image,dtype=np.uint8).reshape(256,256)
    best=None;shift=(0,0)
    for dx,dy in [(0,0)]+[(x,y) for y in range(-8,9) for x in range(-8,9)]:
        roi=current[104+dy:152+dy,104+dx:152+dx].astype(np.int16)
        score=int(np.abs(ref-roi).sum());rank=(score,abs(dx)+abs(dy))
        if best is None or rank<best:best=rank;shift=(dx,dy)
        if dx==0 and dy==0 and score==0:break
    dx,dy=shift;result=np.zeros_like(current)
    x0,x1=max(0,-dx),min(256,256-dx);y0,y1=max(0,-dy),min(256,256-dy)
    result[y0:y1,x0:x1]=current[y0+dy:y1+dy,x0+dx:x1+dx]
    return result.tobytes()

class _PatientPipeline:
    def __init__(self, pipeline, cache, relative_prefix):
        self.pipeline,self.cache=pipeline,cache
        self.prefix=relative_prefix.rstrip('/')+'/'
    def _name(self, source):
        path=source.get('path','')
        if not path.startswith(self.prefix):raise ValueError('frame is outside the selected patient')
        name=path[len(self.prefix):]
        if name not in self.cache.sources:raise ValueError('frame is not an original selected patient frame')
        return name

class SegmentationPipeline(_PatientPipeline):
    capacity=1
    def __init__(self,*args,alpha=lambda:45,resume_reference=None):
        super().__init__(*args);self.alpha=alpha
        self.resume_reference=resume_reference
        self._worker=ThreadPoolExecutor(max_workers=1,thread_name_prefix='patient-segmentation')
    def submit(self,source,mode):
        name=self._name(source)
        return self._worker.submit(self._segment,name,dict(source),mode)
    def _segment(self,name,source,mode):
        try:planes=self.cache.read(name,source['data'])
        except (OSError,ValueError,KeyError):planes=None
        if planes is not None:
            a=np.empty((65536,4),dtype=np.uint8)
            for i,key in enumerate(('gray','mask','contour')):a[:,i]=np.frombuffer(planes[key],dtype=np.uint8)
            a[:,3]=255
            return {'ok':True,'raw':preview_rgba(a.tobytes(),mode,self.alpha()),'readback':{},
                    'cached':True,'frames':0,'timings_ms':{'transfer_ms':0}}
        packet=dict(source)
        if self.resume_reference is not None:
            packet['data']=register_to_reference(self.resume_reference,source['data'])
            packet['index']=0
        # First pass keeps registration, complete U-Net, metrics, HDMI and S2MM.
        first=self.pipeline.submit({**packet,'medical_job':0,'semantic_return':True},mode).result()
        gray,mask,_=semantic_planes(first['raw'])
        # Second pass receives semantic masks, bypasses U-Net AND metrics, and
        # runs the independently stallable four-neighbour contour engine.
        second=self.pipeline.submit({'data':packed_input(gray,mask),'medical_job':1,
                                     'semantic_return':True,'index':-1},mode).result()
        new_gray,new_mask,_=semantic_planes(second['raw'])
        if gray!=new_gray or mask!=new_mask:raise ValueError('mask-to-contour pass changed gray or masks')
        self.cache.save_async(name,source['data'],second['raw'])
        first['raw']=preview_rgba(second['raw'],mode,first.get('readback',{}).get('mask_transparency',self.alpha()))
        first['segmentation_pass_jobs']=[first['job'],second['job']]
        first['cache_saving']=True
        first['timings_ms']['contour_transfer_ms']=second['timings_ms']['transfer_ms']
        first['timings_ms']['transfer_ms']+=second['timings_ms']['transfer_ms']
        return first
    def close(self):
        try:
            self._worker.shutdown(wait=True)
            self.cache.close()
        finally:self.pipeline.close()

class AnalysisPipeline(_PatientPipeline):
    @property
    def capacity(self):return self.pipeline.capacity
    def submit(self,source,mode):
        name=self._name(source);planes=self.cache.read(name,source['data'])
        packet=packed_input(planes['gray'],planes['mask'],planes['contour'])
        return self.pipeline.submit({**source,'data':packet,'medical_job':2},mode)
    def close(self):
        try:self.pipeline.close()
        finally:self.cache.close()
