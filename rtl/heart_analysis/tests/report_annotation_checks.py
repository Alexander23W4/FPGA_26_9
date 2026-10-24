"""Summarize real-annotation checks without claiming clinical accuracy."""
import argparse, csv, json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from prepare_cardiac_annotations import read_nii, fit, disc_sum

def csv_write(path, rows):
    if rows:
        with path.open('w',newline='',encoding='utf-8-sig') as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

def font(size):
    return ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',size)

def overlay(gray,bits):
    rgb=np.repeat(gray[:,:,None],3,axis=2).astype(float)
    for c,color in enumerate(((245,105,105),(180,125,245),(50,180,255),(95,220,145))):
        selected=(bits&(1<<c))!=0
        rgb[selected]=.6*rgb[selected]+.4*np.array(color)
    return Image.fromarray(np.uint8(rgb))

def preview(rec,a,pair,out):
    path=Path(rec['source_label']).with_name(rec['name']+'_image.nii.gz')
    image,_=read_nii(path)
    panel=Image.new('RGB',(816,500),'#f5f6f8');d=ImageDraw.Draw(panel)
    d.text((16,8),rec['name']+' | real annotation overlays',fill='#252936',font=font(20))
    for slot,(key,metric) in enumerate((('ed_frame','EDV_LV'),('es_frame','ESV_LV'))):
        idx=int(pair[key]);gray,_=fit(image[:,:,idx].T[::-1,:],(256,256),nearest=False)
        tile=overlay(gray,a['masks'][idx]).resize((384,384),Image.Resampling.NEAREST)
        x=16+slot*400
        d.text((x,42),'%s candidate: frame %d | LV %.2f px^3' %
               ('ED' if slot==0 else 'ES',idx,int(pair[metric])/100),fill='#252936',font=font(16))
        panel.paste(tile,(x,72))
    d.text((16,470),'LV blue | LA red | RA purple | RV green | zero-based frames | no mL calibration',
           fill='#535966',font=font(15))
    name=rec['name']+'_ed_es.png';panel.save(out/name);return name

def camus_check(root,out):
    rows=[]
    for p in sorted((root/'masks').rglob('*_4CH_ED_gt_label.bin')):
        q=p.with_name(p.name.replace('_ED_','_ES_'))
        if not q.is_file():continue
        a=np.fromfile(p,np.uint8).reshape(256,256)==1
        b=np.fromfile(q,np.uint8).reshape(256,256)==1
        x,y,u,v=disc_sum(a),disc_sum(b),disc_sum(a.T),disc_sum(b.T)
        rows.append(dict(patient=p.parent.name,split=p.parent.parent.name,
                         exported_EF=100*(1-y/x),transposed_EF=100*(1-v/u),
                         ED_label=str(p),ES_label=str(q)))
    csv_write(out/'camus_manual_phases.csv',rows)
    if rows:
        gray=np.asarray(Image.open(root/'images/training/patient0001/patient0001_4CH_ED.png').convert('L'))
        label=np.fromfile(root/'masks/training/patient0001/patient0001_4CH_ED_gt_label.bin',np.uint8).reshape(256,256)
        bits=np.uint8(label==1)<<2
        panel=Image.new('RGB',(816,462),'#f5f6f8');d=ImageDraw.Draw(panel)
        d.text((16,8),'CAMUS patient0001 | orientation sensitivity check',fill='#252936',font=font(20))
        for slot,(name,g,b) in enumerate((('Existing export',gray,bits),('Transpose for axis comparison',gray.T,bits.T))):
            x=16+slot*400;d.text((x,42),name,fill='#252936',font=font(16))
            panel.paste(overlay(g,b).resize((384,384),Image.Resampling.NEAREST),(x,70))
        panel.save(out/'camus_orientation.png')
    return rows

def summarize(out,camus_root):
    records=json.loads((out/'cases.json').read_text())
    accepted=[r for r in records if r.get('accepted')]
    all_pairs=[];table=[];images=[]
    for r in accepted:
        folder=Path(r['out']);a=np.load(folder/'masks_and_reference.npz')
        pairs=list(csv.DictReader((folder/'phase_pairs.csv').open()))
        efs=[];pcas=[]
        for p in pairs:
            ed,es=int(p['ed_frame']),int(p['es_frame'])
            ef=100*(1-int(p['ESV_LV'])/int(p['EDV_LV']))
            pca=100*(1-a['pca_volume'][es]/a['pca_volume'][ed])
            al=100*(1-a['area_length_volume'][es]/a['area_length_volume'][ed])
            efs.append('%.2f'%ef);pcas.append('%.2f'%pca)
            all_pairs.append(dict(case=r['name'],ed_frame=ed,es_frame=es,
                EDV_LV_index=int(p['EDV_LV'])/100,ESV_LV_index=int(p['ESV_LV'])/100,
                EF_proxy_percent=ef,PCA_proxy_EF_percent=pca,area_length_proxy_EF_percent=al,
                ED_LV_area=int(a['areas'][ed,2]),ES_LV_area=int(a['areas'][es,2])))
        table.append('| %s | %d | %d | %s | %s |'%(r['name'],r['frames'],len(pairs),
                    ', '.join(efs) or 'none',', '.join(pcas) or 'none'))
        if pairs and r['name'] in ('normal-23-4','patient-17-4'):images.append(preview(r,a,pairs[0],out))
        curve=[dict(frame=i,LV_volume_index=int(v)/100,LV_area=int(a['areas'][i,2]),
                    PCA_proxy=float(a['pca_volume'][i]),area_length_proxy=float(a['area_length_volume'][i]))
               for i,v in enumerate(a['volumes_x100'][:,2])]
        csv_write(folder/'curve.csv',curve)
    csv_write(out/'all_phase_pairs.csv',all_pairs)
    camus=camus_check(camus_root,out) if camus_root.is_dir() else []
    lines=['# 真实标注验证：数学链路、时相与几何模型','',
    '## 结论','',
    '之前公布的 1583.36/175.93、1330.46/98.96 来自合成矩形，不是源数据集。',
    'LV 宽度分别为 12/4、11/3，高度不变，EF 偏高由刺激决定。',
    '那些测试只证明既定公式的计算和读回，不能证明医学合理性。','',
    '本次真实标注测试修正了短暂局部波动触发额外 ED/ES 配对的问题。',
    '几何模型依然是单视图圆形横截面代理，尚未证明临床准确性。','',
    '## 数据来源与处理','',
    '- 本地 CardiacUDA label_all_frame 的真实逐帧边界标注。',
    '- 官方 A4C 标签语义：1=LV、2=LA、3=RA、4=RV；发送顺序为 LA/RA/LV/RV。',
    '- 原分辨率填充封闭边界，再最近邻缩放并补黑边至 256×256，没有用矩形替换。',
    '- normal-27-4 出现标签 6，patient-5-4 出现 5/6；未猜测重映射，先排除这两段。',
    '- 部分非 LV 边界存在未封闭警告，详细帧号见 cases.json，没有自动补画边界。',
    '- 数据集及 E:/camus 导出文件均未修改。','',
    '## RTL 检查范围','',
    '- 8 段、428 帧生成独立逐帧几何参考，驱动真实 RTL 时相模块。',
    '- normal-23-4 的 65 帧、4,259,840 像素逐像素驱动整个模块，包含反压。',
    '- 所有逐帧体积与参考定点计算逐位一致；像素路径和参考体积输入的时相结果一致。',
    '- 自动候选帧保留原始帧号和原始四腔数值，不以滤波值替代测量结果。','',
    '## 时相修正','',
    '修正前 normal-23-4 输出 5 组，含 20→22、40→43 这种短暂局部波动。',
    '三帧中值滤波、至少 5 帧相位间隔及更高峰合并后，输出 2 组。',
    '没有按 EF 正常范围筛选或钳位；5 帧参数仍需根据源视频采样密度配置。','',
    '以下均是几何代理 EF，无临床 EF 真值对照；PCA 列仅比较同一 ED/ES 帧改变切片轴后的敏感性。','',
    '| 序列 | 帧数 | 配对数 | 当前几何代理 EF % | PCA 对齐后代理 EF % |',
    '| --- | ---: | ---: | --- | --- |',*table,'',
    '**patient-17-4 仍有 82.59% 的估算值，没有被改成“正常”。**',
    '没有独立临床真值，不能认定它是真实生理值，也不能把误差都归因于标定。',
    '统一空间系数会在 EF 的比值中消去。','',
    '## CAMUS 人工 ED/ES 交叉检查','',
    '另用 E:/camus 中 500 对明确标为 4CH_ED/4CH_ES 的掩膜，仅取 gt_label.bin 的类别 1。',
    '没有用 gt_mask.bin：现有转换脚本合并了所有非零类别，其中包括心肌和左心房。',
    '这一项是 Python 离线模型比较，不声称 500 对经过 RTL，也不验证自动时相检测。','']
    if camus:
        first=next(r for r in camus if r['patient']=='patient0001')
        neg=[r['patient'] for r in camus if r['transposed_EF']<0]
        lines+=['现有导出声束侧向，沿图像纵向切圆盘对方向敏感。',
        '同一 patient0001 人工 ED/ES 掩膜：导出方向 %.2f%%，转置后 %.2f%%。'%(first['exported_EF'],first['transposed_EF']),
        '没有重写导出文件，转置只用于离线敏感性比较。',
        '转置比较中，%s 仍得到负代理值。需复核该样本、标注及几何模型，不能当作临床负 EF。'%(', '.join(neg)),'']
    lines+=['## 尚未证明的部分','',
    '本地 CardiacUDA 文件没有独立 ED/ES 帧号或临床 EDV/ESV/EF 真值。',
    '因此这里不能计算临床准确率。CAMUS 提供人工时相，但本地导出没有逐例临床 EF 对照。',
    '像素³不是 mL。PS 系数只能校正尺度，不能修正时相或几何模型误差。','',
    '## 可视检查','',*['![真实标注与候选 ED/ES](%s)'%name for name in images],'',
    '![CAMUS 方向敏感性比较](camus_orientation.png)' if camus else '','',
    '## 来源','',
    '- [GraphEcho 官方标签与填充代码](https://github.com/xmed-lab/GraphEcho/blob/main/datasets/cardiac_uda.py)',
    '- [CAMUS 官方人工时相与标注协议](https://www.creatis.insa-lyon.fr/Challenge/camus/evaluation.html)','',
    '数值明细：all_phase_pairs.csv、各病例 phase_pairs.csv/pixel_pairs.csv/curve.csv。',
    '仿真日志在 xsim/；未运行综合或上板。']
    (out/'report.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('REPORT='+str(out/'report.md'),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--camus-root',type=Path,default=Path('E:/camus'))
    args=p.parse_args();summarize(args.out.resolve(),args.camus_root.resolve())
