"""Two medical workflows sharing the existing full-duplex frame transport."""
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
import hashlib
from pathlib import Path
import re
from medical_cache import PatientCache,packed_input,semantic_planes,preview_rgba

@lru_cache(maxsize=8)
def _model_key(source, size, modified, registration_hash, class_map):
    return hashlib.sha256(Path(source).read_bytes()+registration_hash.encode()+class_map.encode()+b'patient-cache-v1').hexdigest()

def model_key(repo):
    source=next((Path(repo)/'ip/ai4chamberseger').glob('*.zip'))
    st=source.stat()
    registration=Path(repo)/'rtl/inter_fr/ddr/registration_ddr.cpp'
    registration_hash=hashlib.sha256(registration.read_bytes()).hexdigest()
    top=(Path(repo)/'rtl/top1.v').read_text(encoding='utf-8')
    class_map=re.search(r"UNET_CLASS_MAP\s*=\s*16'h([0-9a-fA-F]+)",top).group(1)
    return _model_key(str(source),st.st_size,st.st_mtime_ns,registration_hash,class_map)

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
    def __init__(self,*args,alpha=lambda:45):
        super().__init__(*args);self.alpha=alpha
        self._worker=ThreadPoolExecutor(max_workers=1,thread_name_prefix='patient-segmentation')
    def submit(self,source,mode):
        name=self._name(source)
        return self._worker.submit(self._segment,name,dict(source),mode)
    def _segment(self,name,source,mode):
        # First pass keeps registration, complete U-Net, metrics, HDMI and S2MM.
        first=self.pipeline.submit({**source,'medical_job':0,'semantic_return':True},mode).result()
        gray,mask,_=semantic_planes(first['raw'])
        # Second pass receives semantic masks, bypasses U-Net AND metrics, and
        # runs the independently stallable four-neighbour contour engine.
        second=self.pipeline.submit({'data':packed_input(gray,mask),'medical_job':1,
                                     'semantic_return':True,'index':-1},mode).result()
        new_gray,new_mask,_=semantic_planes(second['raw'])
        if gray!=new_gray or mask!=new_mask:raise ValueError('mask-to-contour pass changed gray or masks')
        self.cache.save_async(name,source['data'],second['raw'])
        first['raw']=preview_rgba(second['raw'],mode,self.alpha())
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
