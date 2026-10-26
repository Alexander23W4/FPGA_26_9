"""Independent integer reference from ORIGINAL student weights/quant params.

Double convolution is exact for these bounded integer accumulators; requantizing
and saturation use int64, matching the delivered Q20/Q12 arithmetic.
"""
from pathlib import Path
import json
import re
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/unet/small_check'

class Block(nn.Module):
    def __init__(self,ci,co):
        super().__init__();self.net=nn.Sequential(nn.Conv2d(ci,co,3,padding=1,bias=False),nn.BatchNorm2d(co),nn.ReLU(),nn.Conv2d(co,co,3,padding=1,bias=False),nn.BatchNorm2d(co),nn.ReLU())
    def forward(self,x):return self.net(x)

class FloatStudent(nn.Module):
    def __init__(self):
        super().__init__()
        for name,ci,co in [('e1',1,8),('e2',8,16),('e3',16,32),('e4',32,64),('d3',96,32),('d2',48,16),('d1',24,8)]:setattr(self,name,Block(ci,co))
        self.pool=nn.MaxPool2d(2);self.head=nn.Conv2d(8,5,1)
    def forward(self,x):
        a=self.e1(x);b=self.e2(self.pool(a));c=self.e3(self.pool(b));d=self.e4(self.pool(c))
        for name,skip in [('d3',c),('d2',b),('d1',a)]:d=getattr(self,name)(torch.cat((F.interpolate(d,scale_factor=2,mode='bilinear',align_corners=False),skip),1))
        return self.head(d)

class IntegerReference:
    def __init__(self):
        source=ROOT/'smallerseger/cardiac_fpga_ip'
        self.layout={k:int(v) for k,v in re.findall(r'#define\s+(\w+)\s+(\d+)\s*$',(source/'hls_src/model_layout_fpga5.h').read_text(),re.M)}
        self.w=np.fromfile(source/'weights_fpga_q8.bin',np.int8)
        self.q=torch.from_numpy(np.fromfile(source/'quant_params_fpga_q20_q12.bin','<i4').copy()).long().reshape(-1,2)
        self.ops=json.loads((ROOT/'build/unet/model/model.json').read_text())['ops']
        self.peak_product=0
    def conv(self,x,name):
        op=next(o for o in self.ops if o['name']==name);ci,co,k=op['cin'],op['cout'],op['k']
        start=self.layout['W_'+name]
        weight=torch.from_numpy(self.w[start:start+co*ci*k*k].copy().reshape(co,ci,k,k)).double()
        accum=F.conv2d(x.double(),weight,padding=k//2).long()
        q=self.q[self.layout['P_'+name]//2:self.layout['P_'+name]//2+co]
        product=accum*q[:,0].reshape(1,-1,1,1)
        self.peak_product=max(self.peak_product,int(product.abs().max()))
        rounded=((product.abs()+(1<<19))>>20)*product.sign()
        result=rounded+q[:,1].reshape(1,-1,1,1)
        return result.clamp(0 if op['relu'] else -32768,32767)
    def __call__(self,image):
        x=torch.from_numpy(image.astype(np.int64)).reshape(1,1,256,256)
        x=(x*4096+127)//255
        def pool(x):return F.max_pool2d(x.double(),2).long()
        def up(x):return torch.floor(F.interpolate(x.double(),scale_factor=2,mode='bilinear',align_corners=False)+.5).long()
        a=self.conv(self.conv(x,'E1A'),'E1B');b=self.conv(self.conv(pool(a),'E2A'),'E2B')
        c=self.conv(self.conv(pool(b),'E3A'),'E3B');d=self.conv(self.conv(pool(c),'E4A'),'E4B')
        for stem,skip in [('D3',c),('D2',b),('D1',a)]:d=self.conv(self.conv(torch.cat((up(d),skip),1),stem+'A'),stem+'B')
        return self.conv(d,'HEAD')[0].numpy().astype('<i2')

def expected_pixels(gray,label):
    mask=np.where(label>0,1<<np.maximum(label.astype(np.int16)-1,0),0).astype(np.uint16)
    p=np.pad(label,1);edge=(p[:-2,1:-1]!=label)|(p[2:,1:-1]!=label)|(p[1:-1,:-2]!=label)|(p[1:-1,2:]!=label)
    return gray.astype(np.uint16)|(mask<<8)|((mask*edge)<<12)

def main():
    torch.set_num_threads(4);torch.set_grad_enabled(False);OUT.mkdir(parents=True,exist_ok=True)
    source=ROOT/'smallerseger/cardiac_fpga_ip'
    model=FloatStudent().eval();model.load_state_dict(torch.load(source/'model_fpga_student_best.pth',map_location='cpu',weights_only=True)['state_dict'])
    reference=IntegerReference();files=sorted((ROOT/'build/unet_distill/cache_patient/test').glob('*.npz'))
    if not files:raise ValueError('real held-out frames are required for model verification')
    cases=[(files[0].stem,np.load(files[0])['image']),('blank',np.zeros((256,256),np.uint8)),(files[min(4,len(files)-1)].stem,np.load(files[min(4,len(files)-1)])['image'])]
    reports=[]
    for index,(name,image) in enumerate(cases):
        logits=reference(image);labels=logits.argmax(0).astype(np.uint8)
        floating=model(torch.from_numpy(image.copy()).float().reshape(1,1,256,256)/255).argmax(1)[0].numpy()
        dice=[float(2*((labels==c)&(floating==c)).sum()/max(1,(labels==c).sum()+(floating==c).sum())) for c in range(1,5)]
        image.tofile(OUT/f'case{index}.bin');expected_pixels(image,labels).astype('<u2').tofile(OUT/f'case{index}.pixels');logits.tofile(OUT/f'case{index}.logits')
        reports.append(dict(name=name,label_agreement=float((labels==floating).mean()),per_class_dice_vs_student_float=dice,class_counts=np.bincount(labels.ravel(),minlength=5).tolist()))
        print('SMALL_REFERENCE_CASE',index,json.dumps(reports[-1]),flush=True)
    # Every possible input gray value must survive Q12 round-trip exactly.
    g=np.arange(256,dtype=np.uint32);assert np.array_equal((((g*4096+127)//255)*255+2048)>>12,g)
    (OUT/'reference.json').write_text(json.dumps(dict(cases=reports,peak_requant_product=reference.peak_product,int64_exact=reference.peak_product<(1<<62)),indent=2))
    print('SMALL_INTEGER_REFERENCE_READY',flush=True)

if __name__=='__main__':main()
