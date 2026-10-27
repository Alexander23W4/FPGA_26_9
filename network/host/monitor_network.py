#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import ipaddress
import json
import re
import secrets
import shutil
import socket
import struct
import sys
import threading
import time
import webbrowser
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent
STARTUP_PAGE = (ROOT / 'assets' / 'startup.html').read_text(encoding='utf-8')
sys.path.insert(0, str(ROOT))
import protocol as proto
import web_common
from frame_transfer import FrameTransferClient, normalize_result_name
from queued_stream import QueuedStream, QueueFull
from frame_pipeline import FramePipeline
from medical_metrics import parse_ps_medical, MedicalCurveHistory
from medical_cache import PatientCache, CACHE_DIR
from medical_workflow import SegmentationPipeline, AnalysisPipeline, model_key, legacy_model_key


def load_gray(path):
    path = Path(path)
    if path.suffix.lower() == '.bin':
        data = np.fromfile(path, dtype=np.uint8)
        if data.size != 256 * 256:
            raise ValueError('BIN must be 65536 bytes')
        return data.reshape(256, 256)
    image = Image.open(path).convert('L').resize((256, 256), Image.Resampling.BILINEAR)
    return np.asarray(image, dtype=np.uint8)


class TcpControlWorker:
    def __init__(self, state, host, port):
        self.state = state
        self.host = host
        self.port = port
        self.stop_event = threading.Event()
        self.sock = None
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        try:
            if self.sock is not None:
                self.sock.close()
        except OSError:
            pass

    def run(self):
        while not self.stop_event.is_set():
            try:
                sock = socket.create_connection((self.host, self.port), timeout=2.0)
                sock.settimeout(0.2)
                self.sock = sock
                self.state.serial_connected = True
                self.state.log(f'控制连接成功 {self.host}:{self.port}')
                decoder = proto.FrameDecoder()
                while not self.stop_event.is_set():
                    try:
                        data = sock.recv(8192)
                    except socket.timeout:
                        continue
                    if not data:
                        break
                    for packet in decoder.feed(data):
                        self.state.handle_packet(packet)
                self.state.log('控制连接断开')
            except OSError as exc:
                self.state.log(f'控制连接失败: {exc}')
            finally:
                self.state.serial_connected = False
                try:
                    if self.sock is not None:
                        self.sock.close()
                except OSError:
                    pass
                self.sock = None
            if not self.stop_event.is_set():
                time.sleep(1.0)

    def write(self, packet):
        with self.lock:
            if self.sock is None:
                return False
            try:
                self.sock.sendall(packet)
                return True
            except OSError as exc:
                self.state.log(f'控制发送失败: {exc}')
                return False


class TcpImageSender:
    def __init__(self, host, port, chunk_size=4096):
        self.host = host
        self.port = port
        self.chunk_size = chunk_size

    def send_file(self, path, frame_id=1):
        return self.send_image(load_gray(path), frame_id)

    def send_image(self, image, frame_id=1):
        if image.shape != (256, 256):
            raise ValueError(f'expected 256x256 image, got {image.shape}')
        packets = proto.encode_image_packets(image.tobytes(), 256, 256, frame_id, self.chunk_size)
        start = time.perf_counter()
        with socket.create_connection((self.host, self.port), timeout=3.0) as sock:
            for packet in packets:
                sock.sendall(packet)
        elapsed = time.perf_counter() - start
        return {'frame_id': frame_id, 'packets': len(packets), 'bytes': image.size,
                'elapsed_ms': elapsed * 1000.0,
                'Mbps': image.size * 8.0 / max(elapsed, 1e-9) / 1e6}


TAIL_SCRIPT = r"""<script>
let dshTransferBusy = false;
let dshCurrentFile = null;
let dshNeedsUpload = false;
function dshOutputMode(){return document.getElementById(document.getElementById('systemMode').value==='medical'?'medicalOutputMode':'fpgaOutputMode').value;}
let dshStreamMode = false;
let dshStreamRunning = false;
let dshFastStream = false, dshStreamWorker = null, dshPreviewGeneration = 0;
let dshFpsPaused = false;
let dshStreamFiles = [], dshStreamIndex = 0, dshStreamFolder = '';
let dshStreamSignature = '', dshStreamQueue = [];
let dshStreamSamples = [], dshStreamCompleted = 0;
let dshMedicalPatient = null, dshMedicalEntries = [], dshMedicalStatus = null;
const dshNow = () => typeof performance !== 'undefined' ? performance.now() : Date.now();
function dshResetPerformance(resetFps = false) {
    if (resetFps) { dshStreamSamples = []; resetFrameRate(); }
    dshStreamCompleted = 0;
  document.getElementById('streamPerformance').hidden = false;
  document.getElementById('streamFps').textContent = '等待首帧回传…';
  document.getElementById('streamFrameTime').textContent = '';
  document.getElementById('streamTiming').textContent = '';
  for(const id of ['streamPsTiming','streamPcTiming','streamTcpTiming','streamNetConfig'])
    document.getElementById(id).textContent='';
}
function dshRecordFrame(result, frameStarted) {
  const now = dshNow(), t = result.timings_ms || {};
  dshStreamCompleted++;
    if (!dshFpsPaused) { dshStreamSamples.push(now); dshUpdateStreamFps(now); }
  document.getElementById('streamFrameTime').textContent =
    '本帧 ' + (now - frameStarted).toFixed(0) + ' ms · 已回传 ' + dshStreamCompleted + ' 帧';
  document.getElementById('streamTiming').textContent =
    '网口/板端 ' + Math.max(0, (t.transfer_ms || 0) - (t.pc_files_ms || 0)).toFixed(0) +
    ' ms · PC 文件 ' + (t.pc_files_ms || 0).toFixed(0) +
    ' ms · 状态回读 ' + (t.readback_ms || 0).toFixed(0) + ' ms';
}
function dshUpdateStreamFps(now = dshNow()) {
    if (dshFpsPaused) { document.getElementById('streamFps').textContent = '回传 0.0 FPS'; return; }
    dshStreamSamples = dshStreamSamples.filter(time => time >= now - 10000);
    const elapsed = dshStreamSamples.length > 1 ? Math.min(10000, now - dshStreamSamples[0]) : 0;
    const fps = elapsed > 0 ? (dshStreamSamples.length - 1) * 1000 / elapsed : 0;
    document.getElementById('streamFps').textContent = '回传 ' + fps.toFixed(1) + ' FPS';
}
setInterval(dshUpdateStreamFps, 500);
function dshValidateBin(file) {
  if (!file || !file.name.toLowerCase().endsWith('.bin') || file.size !== 65536)
    throw new Error('请选择 256x256x8-bit 的 BIN 文件，大小必须恰好为 65536 字节');
}
async function dshRun(action) {
  if (dshTransferBusy) return;
    if (!dshStreamRunning) {
        dshFpsPaused = false;
        if (typeof resumeFrameRate === 'function') resumeFrameRate();
    }
  const status = document.getElementById('processingStatus');
  const controls = ['imageFile', 'chooseImage', 'chooseStream', 'medicalSegment', 'medicalAnalyze', 'medicalClear', 'streamFolder', 'fpgaOutputMode', 'medicalOutputMode', 'thresholdMode',
    'threshold', 'thresholdUpdate', 'maskOpacity', 'maskOpacityUpdate', 'hdmiOutputToggle', 'sourceFps', 'request'];
  const disabled = controls.map(id => document.getElementById(id).disabled);
  dshTransferBusy = true;
  controls.forEach(id => { document.getElementById(id).disabled = true; });
  if (typeof updateModeMenu === 'function') updateModeMenu();
  status.textContent = '处理中，等待回传保存…';
  try {
    await action();
    status.textContent = '';
  } catch (e) {
    status.textContent = '';
    alert('处理失败: ' + e.message);
  } finally {
    dshTransferBusy = false;
    controls.forEach((id, i) => { document.getElementById(id).disabled = disabled[i]; });
    if (typeof updateModeMenu === 'function') updateModeMenu();
    if (typeof updateThresholdControls === 'function') updateThresholdControls();
  }
}
async function dshProcess(upload) {
  if (dshNeedsUpload && (dshCurrentFile || document.getElementById('imageFile').files[0])) upload = true;
  const mode = dshOutputMode();
  let response;
  if (upload) {
    const file = dshCurrentFile || document.getElementById('imageFile').files[0];
    dshValidateBin(file);
    response = await fetch('/api/network/transfer?index=0&name=' + encodeURIComponent(file.name) + '&mode=' + mode,
      {method: 'POST', headers: {'Content-Type': 'application/octet-stream'}, body: await file.arrayBuffer()});
  } else {
    response = await fetch('/api/network/render?mode=' + mode);
  }
  const result = await response.json();
  if (result.timeout) dshNeedsUpload = true;
  if (typeof renderProcessedResults === 'function' && result.results) {
    const previous = upload ? {} : processedResults;
    renderProcessedResults({...previous, ...Object.fromEntries(result.results.map(item => [String(item.mode), item]))}, result.results_revision);
  }
  if (!response.ok || !result.ok) throw new Error(result.log || result.error);
  if (result.readback) dshApplyReadback(result.readback);
  if (upload) dshNeedsUpload = false;
  if (mode !== '5') lastConfirmedVideoMode = Number(mode);
  await poll();
}
async function dshTransfer() { return dshRun(() => dshProcess(true)); }
async function dshParameter(action) {
  if (!dshStreamRunning) return dshRun(action);
  try {
    await new Promise((resolve, reject) => {
      dshStreamQueue.push({action, resolve, reject});
      if(dshStreamWorker)dshStreamWorker.postMessage({type:'pause'});
    });
  } catch (error) { alert('参数更新失败: ' + error.message); }
}
async function dshThrUpdate() {
  const manual = document.getElementById('thresholdMode').getAttribute('aria-checked') === 'true';
  const value = document.getElementById('threshold').value;
  return dshParameter(async () => {
    const j = await (await fetch('/api/serial/threshold?mode=' + (manual ? 1 : 0) + '&value=' + value)).json();
    if (!j.ok) throw new Error('阈值更新失败: ' + j.log);
    if (!dshStreamMode && (dshCurrentFile || document.getElementById('imageFile').files[0])) await dshProcess(true);
    if (!dshStreamRunning) await dshReadback();
  });
}
function dshApplyReadback(j, updateMedical = true) {
    if (!j.ok) throw new Error('状态回读失败: ' + j.log);
    if (updateMedical && typeof renderMedicalMetrics === 'function') renderMedicalMetrics(j);
    document.getElementById('dshRbMode').textContent = j.mode === 1 ? '手动' : '自动';
    document.getElementById('dshRbThr').textContent = j.actual_threshold;
    const names = ['去噪处理', '轮廓处理', '二值掩膜处理', '叠加掩膜处理', '伪彩色热力图处理'];
    document.getElementById('dshRbVid').textContent = names[j.video_mode] || ('未知(' + j.video_mode + ')');
    const area = document.getElementById('dshRbLes');
    const unit = document.createElement('span');
    unit.className = 'unit'; unit.textContent = ' mm²';
    const pixels = document.createElement('span');
    pixels.className = 'sub-value'; pixels.textContent = j.lesion_pixels + ' px';
    area.replaceChildren(document.createTextNode(j.lesion_mm2), unit, pixels);
    document.getElementById('dshRbAlpha').textContent = j.mask_transparency + '%';
    if (j.hdmi_enabled !== undefined) dshSetHdmiState(j.hdmi_enabled === 1);
    lastConfirmedVideoMode = j.video_mode;
    if (!dshStreamMode && !dshTransferBusy) {
      if(document.getElementById('systemMode').value==='medical') {
        if(j.video_mode===1||j.video_mode===3)document.getElementById('medicalOutputMode').value=String(j.video_mode);
      } else if(document.getElementById('fpgaOutputMode').value!=='5') document.getElementById('fpgaOutputMode').value=j.video_mode;
    }
    if (!dshStreamMode) {
      document.getElementById('maskOpacity').value = j.mask_transparency;
      document.getElementById('maskOpacityValue').textContent = j.mask_transparency;
    }
    if (typeof updateOverlayControls === 'function') updateOverlayControls();
    updatePreviewLayout();
}
async function dshReadback(queued = false) {
  if (dshStreamRunning && queued !== true) return dshParameter(() => dshReadback(true));
  try {
    dshApplyReadback(await (await fetch('/api/serial/readback')).json());
  } catch (e) { alert('readback err: ' + e); }
}
document.getElementById('request').addEventListener('click', dshReadback);
document.getElementById('chooseImage').addEventListener('click', () => {
  const picker = document.getElementById('imageFile');
  picker.value = ''; // Selecting the same file also permits another processing attempt.
  picker.click();
});
document.getElementById('imageFile').addEventListener('change', async e => {
  const file = e.target.files[0];
  if (!file) return;
  await dshRun(async () => {
    dshValidateBin(file);
    const response = await fetch('/api/image?name=' + encodeURIComponent(file.name),
      {method: 'POST', headers: {'Content-Type': 'application/octet-stream'}, body: await file.arrayBuffer()});
    const j = await response.json();
    if (!response.ok || !j.ok) throw new Error(j.error || j.log);
    dshStreamMode = false;
    dshFastStream = false; dshPreviewGeneration++;
    document.getElementById('streamPerformance').hidden = true;
    document.getElementById('fullDisplayOption').disabled = false;
    updatePreviewLayout();
    dshCurrentFile = file;
    if(j.image)showOriginalFrame(j.image,j.name,j.source_revision);
    document.getElementById('imageName').textContent = '当前图像: ' + j.name;
    renderProcessedResults({});
    await poll();
    if (isProcessingMode()) await dshProcess(true);
  });
});
let lastConfirmedVideoMode = 0;
async function dshOutputModeChanged(e) {
  if (dshStreamMode) {
    if(dshStreamWorker)dshStreamWorker.postMessage({type:'mode',mode:e.target.value});
    return; // The next input frame carries the requested mode.
  }
  await dshRun(async () => {
    const message = await dshProcess(false); await dshReadback(); return message;
  });
}
document.getElementById('fpgaOutputMode').addEventListener('change',dshOutputModeChanged);
document.getElementById('medicalOutputMode').addEventListener('change',dshOutputModeChanged);
document.getElementById('maskOpacityUpdate').addEventListener('click', async e => {
  const button = e.currentTarget;
  const value = document.getElementById('maskOpacity').value;
  await dshParameter(async () => {
    const result = await (await fetch('/api/serial/mask_transparency?value=' + value)).json();
    if (!result.ok) throw new Error('掩膜透明度更新失败: ' + result.log);
    button.textContent = '已更新';
    if (!dshStreamMode && (dshCurrentFile || document.getElementById('imageFile').files[0])) await dshProcess(true);
    if (!dshStreamRunning) await dshReadback();
  });
});

function dshSetHdmiState(enabled) {
  document.getElementById('hdmiOutputToggle').setAttribute('aria-checked', String(enabled));
  document.getElementById('hdmiOutputLabel').textContent = 'HDMI 输出：' + (enabled ? '开' : '关');
}
document.getElementById('hdmiOutputToggle').addEventListener('click', async () => {
  const enabled = document.getElementById('hdmiOutputToggle').getAttribute('aria-checked') !== 'true';
  await dshParameter(async () => {
    const result = await (await fetch('/api/serial/hdmi_enable?value=' + (enabled ? 1 : 0))).json();
    if (!result.ok) throw new Error('HDMI 开关更新失败: ' + result.log);
    dshSetHdmiState(result.hdmi_enabled === 1);
    // A single image needs a fresh upload when HDMI is re-enabled. Streaming
    // already supplies the next frame; never insert an extra upload there.
    if (enabled && !dshStreamMode && (dshCurrentFile || document.getElementById('imageFile').files[0]))
      await dshProcess(true);
  });
});

function dshStreamControls() {
  const stopping = !dshStreamRunning && dshTransferBusy;
  document.getElementById('chooseImage').disabled = dshStreamRunning || dshTransferBusy;
  document.getElementById('chooseStream').textContent = dshStreamRunning ? '停止流' : '选择流文件夹';
  document.getElementById('chooseStream').disabled = !dshStreamRunning && dshTransferBusy;
  for (const id of ['fpgaOutputMode', 'medicalOutputMode', 'thresholdUpdate', 'maskOpacity', 'maskOpacityUpdate', 'hdmiOutputToggle', 'sourceFps', 'request'])
    document.getElementById(id).disabled = stopping;
  document.getElementById('fullDisplayOption').disabled = dshStreamMode;
  document.getElementById('medicalSegment').disabled = dshTransferBusy || dshStreamRunning || !dshMedicalPatient || !!(dshMedicalStatus&&dshMedicalStatus.complete);
  document.getElementById('medicalClear').disabled = dshTransferBusy || dshStreamRunning || !dshMedicalPatient;
  document.getElementById('medicalAnalyze').disabled = dshTransferBusy || dshStreamRunning || !dshMedicalPatient || !dshMedicalStatus || !dshMedicalStatus.complete;
  updateModeMenu(); updateThresholdControls(); updatePreviewLayout();
}
function dshStopStream() {
  dshStreamRunning = false; // Let the current frame finish; never truncate MM2S.
  if(dshStreamWorker)dshStreamWorker.postMessage({type:'stop'});
    dshFpsPaused = true; dshStreamSamples = []; resetFrameRate(true); dshUpdateStreamFps();
  dshStreamControls();
  document.getElementById('chooseStream').disabled = true;
  document.getElementById('chooseStream').textContent = '已停止排队，本帧收尾中…';
}
async function dshDrainStreamControls() {
  while (dshStreamQueue.length) {
    const request = dshStreamQueue.shift();
    try { await request.action(); request.resolve(); }
    catch (error) { request.reject(error); dshStreamRunning = false; return; }
  }
}
function dshApplyFastStats(stats) {
  if(!stats)return;
  dshStreamCompleted=stats.completed;dshStreamIndex=stats.index;
  if(!dshFpsPaused){
    const offset=dshNow()-Date.now();
    dshStreamSamples=stats.times.map(time=>time+offset);dshUpdateStreamFps();
  }
  document.getElementById('streamFrameTime').textContent=
    '本帧 '+stats.frameMs.toFixed(0)+' ms · 已回传 '+stats.completed+' 帧';
  const metadata=stats.metadata,t=metadata.timings_ms,p=metadata.readback.ps_timings_ms||{};
  if(metadata.stream)document.getElementById('streamFrameTime').textContent+=
    ' · Python 待发 '+metadata.stream.pending+'/'+metadata.stream.capacity+' 帧';
  document.getElementById('streamTiming').textContent=
    '收发 '+t.transfer_ms.toFixed(1)+' ms · 板端收包 '+(p.receive||0).toFixed(1)+
    ' ms · 准备 '+(p.setup||0).toFixed(1)+' ms · PL→DDR '+(p.pl_to_ddr||0).toFixed(1)+' ms';
  const interval=metadata.readback.pl_interval;
  if(interval&&interval.sequence)document.getElementById('streamTiming').textContent+=
    ' · 回传启动→下一帧写满 '+interval.elapsed_ms.toFixed(2)+' ms'+
    '（写端反压 '+interval.write_stall_ms.toFixed(2)+' ms）';
  const detail=metadata.readback.ps_detail||{},browser=t.browser||{},server=browser.server||{};
  const ms=value=>(value||0).toFixed(2);
  document.getElementById('streamPsTiming').textContent=
    'PS：输出检查 '+ms(detail.output_check)+' ms · 输出CRC '+ms(detail.output_crc)+
    ' ms · TCP提交 '+ms(detail.tcp_enqueue)+' ms（写入调用 '+ms(detail.tcp_copy)+
    ' ms）· 输入CRC '+ms(detail.input_crc)+' ms · 接收复制 '+ms(detail.rx_copy)+' ms';
  document.getElementById('streamPcTiming').textContent=
    'PC：预读/补帧 '+ms(browser.source_ms)+' ms · 结果HTTP '+ms(browser.http_ms)+
    ' ms（等待结果 '+ms(server.preview_wait)+' ms）· Python响应 '+
    ms(Math.max(0,(server.handler||0)-(server.preview_wait||0)))+
    ' ms · HTTP/浏览器余量 '+ms(browser.http_overhead_ms)+
    ' ms · Worker解包 '+ms(browser.decode_ms)+' ms';
  document.getElementById('streamTcpTiming').textContent=
    'Python TCP：写队列等待 '+ms(t.upload_queue_ms)+' ms · 发送调用 '+ms(t.upload_send_ms)+
    ' ms · 等响应头 '+ms(t.wait_header_ms)+
    ' ms · 收图 '+ms(t.result_receive_ms)+' ms · 校验 '+ms(t.host_validate_ms)+
    ' ms · 计时尾包 '+ms(t.perf_receive_ms)+' ms';
  document.getElementById('streamNetConfig').textContent=
    'TCP窗口 '+(detail.tcp_window_bytes||0)+' B · 发送缓冲 '+(detail.tcp_send_bytes||0)+
    ' B · PS优化 '+(detail.optimized?'开启':'关闭')+' · TCP等待轮询 '+(detail.tcp_wait_polls||0);
}
function dshDrawBin(canvasId,raw,color) {
  const canvas=document.getElementById(canvasId),context=canvas.getContext('2d');
  if(color){context.putImageData(new ImageData(new Uint8ClampedArray(raw),256,256),0,0);return;}
  const pixels=context.createImageData(256,256),source=new Uint8Array(raw),target=pixels.data;
  for(let i=0;i<65536;i++){
    const at=i*4;
    target[at]=source[color?at+2:i];target[at+1]=source[color?at+1:i];
    target[at+2]=source[color?at:i];target[at+3]=255;
  }
  context.putImageData(pixels,0,0);
}
function dshRunStreamWorker(entries,streamChanged,workflow=null) {
  const worker=new Worker('/assets/stream_worker.js');
  const generation=++dshPreviewGeneration;
  let original=null,processed=null,paintPending=false,error=null;
  dshStreamWorker=worker;
  if(streamChanged)for(const id of ['streamOriginalCanvas','streamProcessedCanvas'])
    document.getElementById(id).getContext('2d').clearRect(0,0,256,256);
  function schedulePaint(){
    if(paintPending)return;paintPending=true;
    requestAnimationFrame(()=>{
      paintPending=false;if(generation!==dshPreviewGeneration)return;
      if(original){dshDrawBin('streamOriginalCanvas',original.raw,false);original=null;}
      if(processed){
        const paintStarted=dshNow();
        dshDrawBin('streamProcessedCanvas',processed.raw,true);
        document.getElementById('streamPaintTiming').textContent=
          '最近绘制：等待 '+(paintStarted-processed.queuedAt).toFixed(1)+
          ' ms · Canvas 提交 '+(dshNow()-paintStarted).toFixed(2)+' ms';
        const result=processed.metadata;
        document.getElementById('streamProcessedCanvas').setAttribute('data-result-job',String(result.job));
        document.getElementById('comparisonProcessedLabel').textContent=document.getElementById('systemMode').value==='medical'?'处理流':streamModeLabels[result.mode];
        if(typeof renderMedicalMetrics==='function')renderMedicalMetrics(result.readback);
        updateFrameRate();processed=null;
      }
    });
  }
  return new Promise((resolve,reject)=>{
    worker.onerror=event=>{worker.terminate();dshStreamWorker=null;reject(new Error(event.message));};
    worker.onmessage=async event=>{
      const message=event.data;
      try{
        if(message.type==='source'){
          original=message;document.getElementById('imageName').textContent=dshStreamFolder;
          schedulePaint();worker.postMessage({type:'preview_consumed',kind:'source'});
        }else if(message.type==='result'){
          processed=message;processed.queuedAt=dshNow();dshApplyFastStats(message);dshApplyReadback(message.metadata.readback,false);
          if(workflow==='segmentation')dshSetMedicalSegmentationProgress(dshSegmentationBase+message.completed,dshSegmentationTotal);
          dshNeedsUpload=false;schedulePaint();
          worker.postMessage({type:'preview_consumed',kind:'result'});
        }else if(message.type==='paused'){
          await dshDrainStreamControls();
          worker.postMessage({type:dshStreamRunning?'resume':'stop'});
        }else if(message.type==='error')error=new Error(message.message);
        else if(message.type==='stopped'){
          dshApplyFastStats(message.last);worker.terminate();dshStreamWorker=null;
          if(error)reject(error);else resolve();
        }
      }catch(cause){error=cause;worker.postMessage({type:'stop'});}
    };
    const offset=Date.now()-dshNow();
    worker.postMessage({type:'start',files:entries,index:dshStreamIndex,folder:dshStreamFolder,workflow,
      dataset:dshMedicalPatient&&workflow?dshMedicalPatient.dataset:null,
      patient:dshMedicalPatient&&workflow?dshMedicalPatient.patient:null,
      maskTransparency:Number(document.getElementById('maskOpacity').value),
      mode:dshOutputMode(),
      sourceFps:Number(document.getElementById('sourceFps').value),times:dshStreamSamples.map(t=>t+offset)});
  });
}
function dshSetMedicalCacheStatus(status,error=null){
  dshMedicalStatus=status;
  const lamp=document.getElementById('medicalCacheLamp');
  lamp.className='cache-state '+(status&&status.complete?'cache-complete':'cache-incomplete');
  lamp.textContent=error?'未完成模型分割 · '+error:(status&&status.complete?'已完成模型分割':
    '未完成模型分割'+(status?' · '+status.completed+'/'+status.total+' 帧':''));
  dshStreamControls();
}
function dshSetMedicalSegmentationProgress(completed,total){
  const lamp=document.getElementById('medicalCacheLamp');
  const done=Number.isFinite(completed)?Math.max(0,Math.min(total,completed)):0;
  lamp.className='cache-state cache-working';
  lamp.textContent='模型分割中 '+done+'/'+total+' 帧';
}
async function dshRefreshMedicalCache(){
  if(!dshMedicalPatient)return;
  try{
    const q=new URLSearchParams({dataset:dshMedicalPatient.dataset,patient:dshMedicalPatient.patient});
    const response=await fetch('/api/network/medical/cache?'+q,{cache:'no-store'}),status=await response.json();
    if(!response.ok||!status.ok)throw new Error(status.error||'缓存状态读取失败');
    dshSetMedicalCacheStatus(status);
  }catch(error){dshSetMedicalCacheStatus(null,error.message);}
}
async function dshSelectMedicalPatient(dataset){
  document.getElementById('processingStatus').textContent='选择患者文件夹…';
  try{
    const response=await fetch('/api/network/stream/datasets?dataset='+encodeURIComponent(dataset));
    const catalog=await response.json();document.getElementById('processingStatus').textContent='';
    if(catalog.cancelled)return;
    if(!response.ok||!catalog.ok)throw new Error(catalog.error||'读取患者目录失败');
    const entries=catalog.files.map(item=>({...item,sourceUrl:'/api/network/stream/dataset-frame?'+
      new URLSearchParams({dataset,path:item.path}).toString()}));
    dshMedicalPatient={dataset:catalog.dataset,patient:catalog.patient,folder:catalog.folder};
    if(typeof setCardiacPatient==='function')setCardiacPatient(catalog.dataset+'|'+catalog.patient);
    dshMedicalEntries=entries;dshStreamFolder=catalog.folder;dshStreamFiles=entries;
    dshStreamMode=true;dshStreamSignature=dataset+'\n'+catalog.patient+'\n'+entries.map(x=>x.path).join('\n');
    document.getElementById('imageName').textContent=catalog.folder;
    document.getElementById('comparisonPreview').hidden=false;document.getElementById('singlePreview').hidden=true;
    document.getElementById('streamOriginalCanvas').hidden=false;document.getElementById('streamProcessedCanvas').hidden=false;
    const first=await fetch(entries[0].sourceUrl,{cache:'no-store'});
    if(!first.ok)throw new Error('患者首帧读取失败');
    dshDrawBin('streamOriginalCanvas',await first.arrayBuffer(),false);
    document.getElementById('streamProcessedCanvas').getContext('2d').clearRect(0,0,256,256);
    document.getElementById('comparisonOriginalLabel').textContent='原流';
    document.getElementById('comparisonProcessedLabel').textContent='处理流';
    dshSetMedicalCacheStatus(null);
    await dshRefreshMedicalCache();
    if(dshMedicalPoll)clearInterval(dshMedicalPoll);
    dshMedicalPoll=setInterval(()=>{if(!dshStreamRunning)void dshRefreshMedicalCache();},2000);
  }catch(error){document.getElementById('processingStatus').textContent='';alert('患者目录读取失败: '+error.message);}
}
let dshMedicalPoll=null;
let dshSegmentationBase=0,dshSegmentationTotal=0;
async function dshClearMedicalCache(){
  if(!dshMedicalPatient||dshTransferBusy||dshStreamRunning)return;
  const patient={...dshMedicalPatient};
  if(!confirm('确定清除患者 '+patient.patient+' 的全部分割结果吗？\n已保存的掩膜和轮廓将被删除，需要重新运行 U-Net。原始 BIN 图像不会删除。\n此操作无法撤销。'))return;
  dshTransferBusy=true;dshStreamControls();
  try{
    const response=await fetch('/api/network/medical/clear',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({dataset:patient.dataset,patient:patient.patient,confirm:true})});
    const status=await response.json();
    if(!response.ok||!status.ok)throw new Error(status.error||'清除分割结果失败');
    dshSetMedicalCacheStatus(status);
    document.getElementById('streamProcessedCanvas').getContext('2d').clearRect(0,0,256,256);
    if(typeof clearCardiacPatientHistory==='function')clearCardiacPatientHistory();
  }catch(error){alert('清除分割结果失败: '+error.message);}
  finally{dshTransferBusy=false;dshStreamControls();}
}
async function dshStartStream(files, preset=null, workflow=null) {
  if (dshTransferBusy || dshStreamRunning || systemModePending) return;
  let performanceStarted = false;
  dshTransferBusy = true;
  dshStreamControls();
  try {
    let entries, folder;
    if(workflow){
      if(!dshMedicalPatient||!dshMedicalEntries.length)throw new Error('请先选择一个 Cardiac patient 文件夹');
      if(document.getElementById('systemMode').value!=='medical')throw new Error('请先切换到医学分析模式');
      entries=dshMedicalEntries;folder=dshMedicalPatient.folder;
      await dshRefreshMedicalCache();
      if(workflow==='analysis'&&(!dshMedicalStatus||!dshMedicalStatus.complete))throw new Error('全部图像完成模型分割后才能开始流分析');
      if(workflow==='segmentation'&&dshMedicalStatus&&dshMedicalStatus.complete)return;
      if(workflow==='segmentation'){
        if(!dshMedicalStatus)throw new Error('无法核对已有分割进度，请重试');
        dshSegmentationBase=dshMedicalStatus.completed;dshSegmentationTotal=dshMedicalStatus.total;
        const completed=new Set(dshMedicalStatus.completed_files||[]),prefix=dshMedicalPatient.patient+'/';
        entries=entries.filter(entry=>!completed.has(entry.path.slice(prefix.length)));
      }
      if(!entries.length){await dshRefreshMedicalCache();return;}
    } else if (preset) {
      document.getElementById('processingStatus').textContent =
        preset === 'cardiac' ? '请选择一个 Cardiac patient 文件夹…' : '请选择一个 Camus patient 文件夹…';
      const response = await fetch('/api/network/stream/datasets?dataset=' + encodeURIComponent(preset));
      const catalog = await response.json();
      document.getElementById('processingStatus').textContent = '';
      if (catalog.cancelled) return;
      if (!response.ok || !catalog.ok) throw new Error(catalog.error || '读取流数据集失败');
      folder = catalog.folder;
      entries = catalog.files.map(item => ({...item, sourceUrl:'/api/network/stream/dataset-frame?' +
        new URLSearchParams({dataset:preset,path:item.path}).toString()}));
      if(document.getElementById('systemMode').value==='medical'){
        dshMedicalPatient={dataset:catalog.dataset,patient:catalog.patient,folder:catalog.folder};
        if(typeof setCardiacPatient==='function')setCardiacPatient(catalog.dataset+'|'+catalog.patient);
        dshMedicalEntries=entries;dshStreamFolder=folder;dshStreamFiles=entries;dshStreamMode=true;
        document.getElementById('imageName').textContent=folder;
        document.getElementById('comparisonPreview').hidden=false;document.getElementById('singlePreview').hidden=true;
        document.getElementById('streamOriginalCanvas').hidden=false;document.getElementById('streamProcessedCanvas').hidden=false;
        const first=await fetch(entries[0].sourceUrl,{cache:'no-store'});
        if(!first.ok)throw new Error('患者首帧读取失败');
        dshDrawBin('streamOriginalCanvas',await first.arrayBuffer(),false);
        document.getElementById('streamProcessedCanvas').getContext('2d').clearRect(0,0,256,256);
        document.getElementById('comparisonOriginalLabel').textContent='原流';
        document.getElementById('comparisonProcessedLabel').textContent='处理流';
        dshSetMedicalCacheStatus(null);await dshRefreshMedicalCache();
        if(dshMedicalPoll)clearInterval(dshMedicalPoll);
        dshMedicalPoll=setInterval(()=>{if(!dshStreamRunning)void dshRefreshMedicalCache();},2000);
        return;
      }
    } else {
      entries = Array.from(files).filter(file => file.name.toLowerCase().endsWith('.bin')).map(file => {
        dshValidateBin(file);
        const parts = file.webkitRelativePath.split('/');
        const entryFolder = parts.shift(), path = parts.join('/');
        if (!entryFolder || !path) throw new Error('请选择包含 BIN 图像的文件夹');
        return {file, name:file.name, size:file.size, folder:entryFolder, path};
      });
      folder = entries.length ? entries[0].folder : '';
    }
    if (!entries.length) throw new Error('所选文件夹没有 BIN 图像');
    if (entries.some(entry => !entry.name.toLowerCase().endsWith('.bin') || entry.size !== 65536))
      throw new Error('流数据集中存在不是 65536 字节的 BIN 文件');
    if (!preset && !workflow) {
      if (entries.some(entry => entry.folder !== folder)) throw new Error('一次只能选择一个流文件夹');
      entries.sort((a,b) => a.path.localeCompare(b.path, 'zh-CN', {numeric:true, sensitivity:'base'}));
    }
    const signature = (workflow||preset||'local') + '\n' + folder + '\n' + entries.map(entry => entry.path).join('\n');
    const streamChanged = signature !== dshStreamSignature;
    if (streamChanged) dshStreamIndex = 0;
    dshStreamSignature = signature; dshStreamFolder = folder; dshStreamFiles = entries;
    if (!isProcessingMode()) {
      systemModeRevision++; systemModePending = true;
      try {
        const response = await fetch('/api/system_mode?mode=processing');
        const result = await response.json();
        if (!response.ok || !result.ok) throw new Error(result.error || '系统模式切换失败');
        setSimulateState(false);
      } finally { systemModePending = false; }
    }
    dshStreamMode = true;
    if(typeof Worker === 'undefined')throw new Error('流模式需要支持 Web Worker 的浏览器');
    dshFastStream = true;
    if (document.getElementById('fpgaOutputMode').value === '5') document.getElementById('fpgaOutputMode').value = '0';
    dshFpsPaused = false; resumeFrameRate();
    dshStreamRunning = true; dshStreamControls();
    if(workflow==='segmentation'){
      dshSetMedicalSegmentationProgress(dshSegmentationBase,dshSegmentationTotal);
    }
    dshResetPerformance(streamChanged);
    performanceStarted = true;
    await dshRunStreamWorker(entries,streamChanged,workflow);
  } catch (error) { alert('流处理失败: ' + error.message); }
  finally {
    dshStreamRunning = false; dshTransferBusy = false;
    if (performanceStarted) document.getElementById('streamFrameTime').textContent +=
      (dshStreamCompleted ? ' · 已停止' : '已停止 · 已回传 0 帧');
    for (const request of dshStreamQueue.splice(0)) request.reject(new Error('流已停止，参数尚未更新'));
    document.getElementById('processingStatus').textContent = '';
    dshStreamControls();
    if(workflow==='segmentation')await dshRefreshMedicalCache();
  }
}
document.getElementById('chooseStream').addEventListener('click', () => {
  if (dshStreamRunning) { dshStopStream(); return; }
  if (dshTransferBusy) return;
  document.getElementById('streamDatasetDialog').showModal();
});
document.querySelectorAll('[data-stream-dataset]').forEach(button => button.addEventListener('click', () => {
  const dataset = button.dataset.streamDataset;
  document.getElementById('streamDatasetDialog').close();
  if(document.getElementById('systemMode').value==='medical')void dshSelectMedicalPatient(dataset);
  else void dshStartStream(null, dataset);
}));
document.getElementById('medicalSegment').addEventListener('click',()=>void dshStartStream(null,null,'segmentation'));
document.getElementById('medicalAnalyze').addEventListener('click',()=>void dshStartStream(null,null,'analysis'));
document.getElementById('medicalClear').addEventListener('click',()=>void dshClearMedicalCache());
document.getElementById('streamDatasetClose').addEventListener('click', () =>
  document.getElementById('streamDatasetDialog').close());
document.getElementById('streamDatasetCancel').addEventListener('click', () =>
  document.getElementById('streamDatasetDialog').close());
document.getElementById('streamDatasetDialog').addEventListener('click', event => {
  if (event.target === event.currentTarget) event.currentTarget.close();
});
document.getElementById('streamFolder').addEventListener('change', async e => {
  if (e.target.files.length) await dshStartStream(e.target.files);
});
</script>"""


import os as _os
import subprocess as _sp
import tempfile as _tmp
from pathlib import Path as _Path

_REPO = _Path(__file__).resolve().parents[2]
_SERIAL_PORT = _os.environ.get("SERIAL_PORT", "COM7")
EMMC_FIXED_ADDR = 2048
FRAME_BYTES = 256 * 256
STREAM_DATASETS = {
    'camus': ('Camus', Path(r'E:\camus\images')),
    'cardiac': ('Cardiac', Path(r'E:\cardiarc_extract\cardiacUDC_gui_ready\sequences')),
}
FRAME_DONE_LINE = "RESULT: FRAME_DONE frames=1 bytes=65536"
_SERIAL_LOCK = threading.RLock()
_TRANSFER_LOCK = threading.Lock()
_FRAME_CLIENT = FrameTransferClient()
_DISPLAY_PENDING = None


def _probe_uart(port):
    try:
        import serial
        from serial.tools import list_ports
        available=sorted(item.device for item in list_ports.comports())
    except Exception as error:
        return {'ok':False,'detail':'无法枚举串口：%s'%error}
    match=next((item for item in available if item.upper()==str(port).upper()),None)
    if match:
        try:
            with serial.Serial(match,115200,timeout=0,write_timeout=.2):
                pass
            return {'ok':True,'detail':'%s 已连接且可用（115200 baud）'%match}
        except serial.SerialException as error:
            return {'ok':False,'detail':'%s 已连接但无法打开，请关闭占用串口的程序：%s'%(match,error)}
    found='、'.join(available) if available else '没有检测到 COM 串口'
    return {'ok':False,'detail':'需要 %s；当前检测到：%s'%(port,found)}


def _tcp_probe(host,port,timeout=.45):
    try:
        with socket.create_connection((host,int(port)),timeout=timeout):
            return True
    except OSError:
        return False


def _git_bash():
    configured=_os.environ.get('HEARTCARE_BASH')
    if configured and Path(configured).is_file():return configured
    git=shutil.which('git')
    if git:
        candidate=Path(git).resolve().parent.parent/'bin'/'bash.exe'
        if candidate.is_file():return str(candidate)
    return shutil.which('bash')


def _xilinx_env(repo):
    env=_os.environ.copy()
    temporary=Path(repo)/'build'/'startup'/'tmp'
    temporary.mkdir(parents=True,exist_ok=True)
    for name in ('TMPDIR','TMP','TEMP'):env[name]=str(temporary.resolve())
    return env


def _probe_jtag(repo):
    bash=_git_bash()
    if not bash:
        return {'ok':False,'detail':'找不到 Git Bash，无法检查 JTAG 下载器'}
    script=Path(repo)/'scripts'/'check_jtag.sh'
    try:
        result=_sp.run([bash,str(script)],cwd=str(repo),capture_output=True,text=True,
                       encoding='utf-8',errors='replace',timeout=45,env=_xilinx_env(repo))
        output=(result.stdout+'\n'+result.stderr).strip()
        if result.returncode==0 and 'HEARTCARE_JTAG_OK' in output:
            return {'ok':True,'detail':'已检测到 Cortex-A9 与 FPGA JTAG 目标'}
        detail=next((line.strip() for line in reversed(output.splitlines())
                     if line.strip() and 'HEARTCARE_JTAG' not in line), '')
        return {'ok':False,'detail':detail or 'XSCT 未找到 Cortex-A9/FPGA，请检查 JTAG 与板卡供电'}
    except _sp.TimeoutExpired:
        return {'ok':False,'detail':'JTAG 检查超时；请检查 hw_server、JTAG 线和板卡供电'}
    except Exception as error:
        return {'ok':False,'detail':'JTAG 检查失败：%s'%error}


def _probe_build(repo):
    root=Path(repo);out=root/'build'/'out'
    def local_path(value):
        value=value.strip()
        # build.sh publishes MSYS paths (for example /c/Users/...) because it
        # runs under Git Bash, while this GUI uses native Windows Python.
        match=re.match(r'^/([a-zA-Z])/(.*)$',value)
        if match:
            return Path(match.group(1).upper()+':/')/Path(match.group(2).replace('/',_os.sep))
        path=Path(value)
        return path if path.is_absolute() else root/path

    def stale_inputs(manifest):
        stale=[]
        try:
            rows=manifest.read_text(encoding='utf-8').splitlines()
        except OSError:
            return ['校验清单缺失']
        for row in rows:
            row=row.strip()
            if not row:continue
            pieces=row.split(None,1)
            if len(pieces)!=2:continue
            expected,relative=pieces
            relative=relative.lstrip('* ')
            source=root/relative
            if not source.is_file():
                stale.append(relative);continue
            digest=hashlib.sha256(source.read_bytes()).hexdigest()
            if digest.lower()!=expected.lower():stale.append(relative)
        return stale

    required=[('PL 构建',out/'latest-fpga_26-zynq.path'),
              ('PS 构建',out/'latest-MID_plt-app.path')]
    missing=[]
    for label,pointer in required:
        try:
            directory=local_path(pointer.read_text(encoding='utf-8'))
            expected=('system_wrapper.bit','fpga_26.xsa') if label=='PL 构建' else ('MID_plt.elf','ps7_init.tcl')
            if not directory.is_dir() or any(not (directory/name).is_file() for name in expected):
                missing.append(label)
                continue
            manifest=directory/('PL_INPUTS.sha256' if label=='PL 构建' else 'PS_INPUTS.sha256')
            changed=stale_inputs(manifest)
            if changed:
                missing.append(label+' 已过期（源码变更）')
        except OSError:
            missing.append(label)
    weights=root/'build'/'unet'/'model'/'weights.bin'
    if not weights.is_file() or weights.stat().st_size==0:missing.append('U-Net 权重')
    if missing:
        return {'ok':False,'detail':'缺少或未验证：'+', '.join(missing)+'；请先完成 PL/PS 构建与权重准备'}
    return {'ok':True,'detail':'PL 位流、PS ELF、XSA、PS 初始化脚本和 U-Net 权重均已找到'}


def _ethernet_link(host):
    """A cold board cannot answer TCP before PS has been programmed."""
    command="""$ErrorActionPreference='Stop'; $rows=@(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object {
      $address=$_; $adapter=Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue;
      if($adapter){[pscustomobject]@{ip=$address.IPAddress;prefix=$address.PrefixLength;name=$adapter.Name;status=[string]$adapter.Status}}
    }); ConvertTo-Json -InputObject $rows -Compress"""
    try:
        result=_sp.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',command],
            capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=12)
        if result.returncode:return None
        rows=json.loads(result.stdout.lstrip('\ufeff') or '[]')
        if isinstance(rows,dict):rows=[rows]
        target=ipaddress.ip_address(host)
        for row in rows:
            network=ipaddress.ip_network('%s/%s'%(row['ip'],row['prefix']),strict=False)
            if target in network and row.get('status','').lower()=='up':
                return '%s · %s/%s'%(row['name'],row['ip'],row['prefix'])
    except (OSError,ValueError,KeyError,_sp.TimeoutExpired):
        pass
    return None


def _probe_startup(config):
    host=config['board_ip']
    ports={'帧流 %s'%config['transfer_port']:config['transfer_port']}
    services={name:_tcp_probe(host,port) for name,port in ports.items()}
    ping_ok=False
    try:
        result=_sp.run(['ping','-n','1','-w','1000',host],capture_output=True,text=True,
                       encoding='utf-8',errors='replace',timeout=3)
        ping_ok=result.returncode==0
    except Exception:
        pass
    open_services=[name for name,ok in services.items() if ok]
    link=_ethernet_link(host) if not (ping_ok or open_services) else None
    network_ok=ping_ok or bool(open_services) or bool(link)
    if ping_ok:
        network_detail='%s 可达；项目 TCP 服务：%s'%(host,', '.join(name for name,ok in services.items() if ok) or '烧录后启动')
    elif open_services:
        network_detail='%s 已开放 %s'%(host,', '.join(open_services))
    elif link:
        network_detail='网线链路与 IP 网段已就绪（%s）；烧录后确认 %s:%s 服务'%(link,host,config['transfer_port'])
    else:
        network_detail='%s:%s 未连接，未找到同网段且已连线的网卡；检查网线、网卡 IP 和板卡供电'%(host,config['transfer_port'])
    components={'jtag':_probe_jtag(config['repo']),'uart':_probe_uart(config['serial_port']),
                'ethernet':{'ok':network_ok,'detail':network_detail},
                'build':_probe_build(config['repo'])}
    labels={'jtag':'JTAG 下载器','uart':'USB-UART 串口','ethernet':'板卡以太网','build':'当前构建与模型权重'}
    missing=[labels[key]+'：'+value['detail'] for key,value in components.items() if not value['ok']]
    return {'ok':True,'ready':not missing,'components':components,'missing':missing,
            'board_ip':host,'checked_at':time.time(),
            'services':{name:{'port':ports[name],'open':is_open} for name,is_open in services.items()}}


def _flash_progress(server,**updates):
    with server.flash_lock:
        server.flash_state.update(updates)


def _flash_current_worker(server):
    root=Path(server.startup_config['repo'])
    bash=_git_bash()
    if not bash:
        _flash_progress(server,state='error',error='找不到 Git Bash，无法调用 scripts/flash_current.sh')
        return
    env=_xilinx_env(root)
    weights=root/'build'/'unet'/'model'/'weights.bin'
    if weights.is_file():env['UNET_WEIGHTS']=str(weights.resolve())
    command=[bash,str(root/'scripts'/'flash_current.sh'),'init']
    markers=[('Verified bitstream',8,'验证位流与构建归档'),
             ('APU found',17,'连接 JTAG 并确认 Cortex-A9'),
             ('CPU halted',27,'停止 PS，准备重配置'),
             ('ps7_init done',38,'初始化 PS 与 DDR'),
             ('programming PL',48,'正在配置 FPGA 位流'),
             ('PL programmed',77,'位流配置完成'),
             ('ps7_post_config done',84,'恢复 PS-PL 接口'),
             ('UNET_WEIGHTS_LOADING',86,'正在向 DDR 加载 U-Net 权重'),
             ('UNET_WEIGHTS_READY',94,'U-Net 权重加载完成'),
             ('FLASH_ALL_OK',96,'位流、程序和权重已写入；等待板端服务')]
    log=[];confirmed=False
    try:
        process=_sp.Popen(command,cwd=str(root),env=env,stdout=_sp.PIPE,stderr=_sp.STDOUT,
                          text=True,encoding='utf-8',errors='replace',bufsize=1)
        _flash_progress(server,state='running',progress=4,phase='检查构建并启动 XSCT',message='开始烧录…')
        assert process.stdout is not None
        for line in process.stdout:
            line=line.rstrip()
            if not line:continue
            if line=='FLASH_ALL_OK':confirmed=True
            log.append(line);log=log[-18:]
            update={'message':'\n'.join(log)}
            for marker,progress,phase in markers:
                if marker in line:
                    update.update(progress=progress,phase=phase)
            if '[FAIL]' in line or '!!!' in line:
                update.update(phase='烧录诊断',progress=max(4,server.flash_state.get('progress',4)))
            _flash_progress(server,**update)
        return_code=process.wait()
        if return_code!=0 or not confirmed:
            _flash_progress(server,state='error',error='烧录脚本未确认成功。请查看输出日志。',
                            message='\n'.join(log),progress=0)
            return
        _flash_progress(server,progress=97,phase='等待板端服务启动',message='PL/PS 已烧录，正在检查网口帧流服务…')
        deadline=time.monotonic()+45
        needed=[int(server.startup_config['transfer_port'])]
        while time.monotonic()<deadline:
            open_now=[_tcp_probe(server.startup_config['board_ip'],port,.4) for port in needed]
            if all(open_now):
                server.flash_ready=True
                _flash_progress(server,state='complete',progress=100,phase='全部就绪',
                    message='烧录成功；板端 TCP %s 已就绪。即将进入操作台。'%needed[0],error='')
                return
            time.sleep(.5)
        missing=[str(port) for port,ok in zip(needed,open_now) if not ok]
        _flash_progress(server,state='error',progress=0,phase='板端服务未就绪',
            error='位流与 PS 程序已烧录，但板端 TCP 端口未全部启动：'+', '.join(missing)+
                  '。检查 PS 启动日志、IP 配置和网线后重试。',message='\n'.join(log))
    except Exception as error:
        _flash_progress(server,state='error',progress=0,phase='烧录失败',error='%s: %s'%(type(error).__name__,error),message='\n'.join(log))


def _serial_lock():
    return _SERIAL_LOCK
# CAMUS 数据集 letterbox 之后每个像素代表的面积 (source: camus_pipeline/convert_camus.py:64)
PIXEL_AREA_MM2 = 0.436280886141

# WORD indices. PS multiplies these by 4 for aligned MMIO; UART labels use indices.
PL_REGISTERS = {"MODE": 0x00, "CMD_REG": 0x01, "VIDEO_MODE": 0x02,
                "HDMI_EN": 0x04,
                "STATUS": 0x03, "DATA_REG": 0x20, "LESION": 0x21,
                "MASK_TRANSP": 0x22}

# Optional for compatibility with firmware/mocks predating medical readback.
# Unsigned unit-spacing pixel^3 * 100; PS applies physical calibration later.
# 0xffffffff means no valid phase pair or missing chamber, not measured zero.
MEDICAL_REGISTERS = {"EDV_LA": 0x10, "ESV_LA": 0x11,
                     "EDV_RA": 0x12, "ESV_RA": 0x13,
                     "EDV_LV": 0x14, "ESV_LV": 0x15,
                     "EDV_RV": 0x16, "ESV_RV": 0x17}
READBACK_REGISTERS = {**PL_REGISTERS, **MEDICAL_REGISTERS}


def _board_talk(payload, wait=1.5):
    """往板子串口发字节, 返回板子打印的内容"""
    _lk = _serial_lock(); _lk.acquire()
    try:
        return _board_talk_locked(payload, wait)
    finally:
        _lk.release()


def _board_talk_locked(payload, wait=1.5):
    """Read through END. wait=None lets a D command wait through backpressure."""
    import serial
    s = serial.Serial(_SERIAL_PORT, 115200, timeout=0.3)
    try:
        s.reset_input_buffer(); s.write(payload); s.flush()
        deadline = None if wait is None else time.monotonic() + wait
        buf = bytearray()
        while True:
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                break
            s.timeout = 0.3 if remaining is None else min(0.3, remaining)
            # Drain available bytes; when silent, block for only the next byte.
            # A short END-terminated reply must not wait to fill a 4096-byte read.
            c = s.read(min(4096, s.in_waiting or 1))
            if c:
                buf += c
                if b"===== END =====" in buf:
                    return buf.decode("utf-8", "replace")
        raise TimeoutError("board command did not reach END:\n" +
                           buf.decode("utf-8", "replace"))
    finally:
        s.close()


def _validate_bin_frame(data, filename):
    if Path(filename).suffix.lower() != ".bin":
        raise ValueError("仅支持 256x256x8-bit 的 .bin 文件")
    if len(data) != FRAME_BYTES:
        raise ValueError("BIN 必须恰好为 65536 字节，实际为 %d 字节" % len(data))


def _do_threshold(mode, value):
    if mode not in (0, 1):
        return {"ok": False, "log": "mode must be 0 or 1"}
    v = int(value)
    if not (0 <= v <= 255):
        return {"ok": False, "log": "threshold must be 0..255"}
    try:
        text = _board_talk(b"T" + bytes([mode, v]))
        names = ('CMD_REG', 'DATA_REG') if mode else ('CMD_REG',)
        regs = _parse_pl_registers(text, names)
        if regs['CMD_REG'] != mode or (mode and regs['DATA_REG'] != v):
            raise ValueError('threshold register readback mismatch\n' + text)
        return {"ok": True, "log": text}
    except Exception as exc:
        return {"ok": False, "log": "%s: %s" % (type(exc).__name__, exc)}


def _parse_pl_registers(text, required):
    import re
    values = {}
    for name, address, value in re.findall(
            r"^\[PL rdbk\]\s+(\w+)\(0x([0-9a-fA-F]+)\)\s*=\s*(\d+)\s*$",
            text, re.M):
        if name in READBACK_REGISTERS:
            if int(address, 16) != READBACK_REGISTERS[name]:
                raise ValueError("register map mismatch for %s; rebuild/flash matching PS and PL" % name)
            values[name] = int(value)
            if name in MEDICAL_REGISTERS and values[name] > 0xffffffff:
                raise ValueError("medical volume is not an unsigned 32-bit value: " + name)
    missing = [name for name in required if name not in values]
    if missing:
        raise ValueError("missing register readback: " + ", ".join(missing))
    return values


def _readback_regs():
    """R returns all WORD-indexed registers, including the new overlay opacity."""
    try:
        txt = _board_talk(b"R", wait=2.0)
        regs = _parse_pl_registers(txt, PL_REGISTERS)
        lesion = regs["LESION"]
        medical_raw = {name: regs[name] for name in MEDICAL_REGISTERS if name in regs}
        medical_index = {name: (None if value == 0xffffffff else
                            "%d.%02d" % divmod(value, 100))
                      for name, value in medical_raw.items()}
        return {"ok": True, "mode": regs["CMD_REG"], "system_mode": regs["MODE"],
                "threshold": regs["DATA_REG"], "actual_threshold": regs["STATUS"],
                "video_mode": regs["VIDEO_MODE"], "lesion_pixels": lesion,
                "mask_transparency": regs["MASK_TRANSP"],
                "hdmi_enabled": regs["HDMI_EN"],
                "medical_raw": medical_raw, "medical_volume_index": medical_index,
                "medical_volume_unit": "px^3",
                "lesion_mm2": "%.3f" % (lesion * PIXEL_AREA_MM2), "log": txt,
                **parse_ps_medical(txt)}
    except Exception as exc:
        return {"ok": False, "log": "%s: %s" % (type(exc).__name__, exc)}


def _write_byte_register(command, value, name, maximum):
    try:
        requested = int(value)
        if not 0 <= requested <= maximum:
            raise ValueError("%s must be 0..%d" % (name, maximum))
        txt = _board_talk(command + bytes([requested]))
        actual = _parse_pl_registers(txt, (name,))[name]
        if actual != requested:
            raise ValueError("%s readback mismatch: requested %d, got %d\n%s" %
                             (name, requested, actual, txt))
        return {"ok": True, "value": actual, "log": txt}
    except Exception as exc:
        return {"ok": False, "log": "%s: %s" % (type(exc).__name__, exc)}


def _set_video_mode(mode):
    result = _write_byte_register(b"V", mode, "VIDEO_MODE", 4)
    if result["ok"]:
        result.update(mode=result["value"], video_mode=result["value"])
    return result


def _set_system_mode(mode):
    result = _write_byte_register(b"M", mode, "MODE", 1)
    if result["ok"]:
        result["reg_mode"] = result["value"]
    return result


def _set_source_fps(value):
    try:
        fps=int(value)
        if not 1<=fps<=100:raise ValueError('源视频 FPS 必须为 1..100')
        text=_board_talk(b'F'+bytes([fps]))
        match=re.search(r'^\[PS timing\] SOURCE_FPS = (\d+)\s*$',text,re.M)
        if not match or int(match[1])!=fps:raise ValueError('PS 源帧率设置未确认\n'+text)
        return {'ok':True,'source_fps':fps}
    except Exception as exc:
        return {'ok':False,'log':str(exc)}


def _require_return_path(state):
    # Both pipelines now produce full return frames. Firmware checks UNET_STATUS
    # before medical jobs, so missing/mismatched DDR weights fail explicitly.
    return


def _set_mask_transparency(value):
    result = _write_byte_register(b"P", value, "MASK_TRANSP", 100)
    if result["ok"]:
        result["mask_transparency"] = result["value"]
    return result


def _set_hdmi_enable(value):
    result = _write_byte_register(b"H", value, "HDMI_EN", 1)
    if result["ok"]:
        result["hdmi_enabled"] = result["value"]
    return result


def load_to_emmc(bin_bytes, emmc_addr):
    ps1 = _REPO / "scripts" / "pc" / "emmc_add.ps1"
    if not ps1.is_file():
        return False, "missing ps1"
    _lk = _serial_lock(); _lk.acquire()
    try:
        return _load_to_emmc_locked(bin_bytes, emmc_addr)
    finally:
        _lk.release()


def _load_to_emmc_locked(bin_bytes, emmc_addr):
    _validate_bin_frame(bin_bytes, "image.bin")
    ps1 = _REPO / "scripts" / "pc" / "emmc_add.ps1"
    tmp = _os.path.join(_tmp.gettempdir(), "dsh_fpga_upload.bin")
    with open(tmp, "wb") as fh:
        fh.write(bin_bytes)
    cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(ps1),
           "-File", tmp, "-Port", _SERIAL_PORT, "-StartBlock", str(emmc_addr),
           "-Width", "256", "-Height", "256", "-Bpp", "1"]
    try:
        p = _sp.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300, cwd=str(_REPO))
        return (p.returncode == 0), ((p.stdout or "") + (p.stderr or "")).strip()
    except Exception as exc:
        return False, "%s: %s" % (type(exc).__name__, exc)


def emmc_clear_catalog():
    return _board_talk(b"E", wait=300.0)


def emmc_to_ddr_play_once(index=0):
    return _board_talk(b"D" + (int(index) & 0xFFFFFFFF).to_bytes(4, "little"), wait=None)


def _stream_target(folder, relative, filename):
    if not folder or '/' in folder or '\\' in folder:
        raise ValueError('流文件夹名称无效')
    result_name = normalize_result_name(folder + '/' + relative)
    if result_name.split('/')[-1] != filename:
        raise ValueError('流图像名称与相对路径不一致')
    return result_name


def _natural_path_key(value):
    return tuple(int(part) if part.isdigit() else part.casefold()
                 for part in re.split(r'(\d+)', value))


def _dataset_root(dataset):
    if dataset not in STREAM_DATASETS:
        raise ValueError('未知流数据集')
    label, configured_root = STREAM_DATASETS[dataset]
    root = configured_root.resolve()
    if not root.is_dir():
        raise FileNotFoundError(f'{label} 数据目录不存在: {root}')
    return label, root


def _dataset_file(dataset, relative):
    label, root = _dataset_root(dataset)
    if not relative or '\\' in relative or relative.startswith('/'):
        raise ValueError('数据集相对路径无效')
    parts = relative.split('/')
    if any(part in ('', '.', '..') for part in parts):
        raise ValueError('数据集相对路径无效')
    path = root.joinpath(*parts).resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise ValueError('数据集路径越界') from exc
    if not path.is_file() or path.suffix.lower() != '.bin':
        raise FileNotFoundError(f'{label} BIN 文件不存在: {relative}')
    if path.stat().st_size != FRAME_BYTES:
        raise ValueError(f'{label} BIN 必须恰好为 {FRAME_BYTES} 字节: {relative}')
    return label, path


def _choose_dataset_folder(dataset):
    """Open a native folder picker at the dataset root and return one selected patient folder."""
    label, root = _dataset_root(dataset)
    import tkinter as tk
    from tkinter import filedialog

    window = tk.Tk()
    window.withdraw()
    window.attributes('-topmost', True)
    try:
        selected = filedialog.askdirectory(
            parent=window,
            title=f'选择一个 {label} 患者文件夹',
            initialdir=str(root),
            mustexist=True,
        )
    finally:
        window.destroy()
    if not selected:
        return label, root, None

    selected = Path(selected).resolve()
    try:
        selected.relative_to(root)
    except ValueError as exc:
        raise ValueError(f'所选目录必须位于 {label} 数据目录内') from exc
    if selected == root:
        raise ValueError('请选择一个具体的 patient 文件夹，不要选择整个数据集目录')
    if not selected.is_dir():
        raise FileNotFoundError(f'所选 {label} 患者目录不存在: {selected}')
    return label, root, selected


def _dataset_catalog(dataset, selected_folder):
    label, root = _dataset_root(dataset)
    selected = Path(selected_folder).resolve()
    try:
        selected.relative_to(root)
    except ValueError as exc:
        raise ValueError(f'所选目录必须位于 {label} 数据目录内') from exc
    if selected == root:
        raise ValueError('请选择一个具体的 patient 文件夹，不要选择整个数据集目录')
    if not selected.is_dir():
        raise FileNotFoundError(f'所选 {label} 患者目录不存在: {selected}')
    files = sorted((path for path in selected.rglob('*.bin') if path.is_file()
                    and CACHE_DIR not in path.relative_to(selected).parts),
                   key=lambda path: _natural_path_key(path.relative_to(root).as_posix()))
    if not files:
        raise FileNotFoundError(f'所选 {label} 患者目录中没有 BIN 图像: {selected}')
    entries = []
    for path in files:
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        if size != FRAME_BYTES:
            raise ValueError(f'{label} BIN 必须恰好为 {FRAME_BYTES} 字节: {relative}')
        entries.append({'name': path.name, 'path': relative, 'size': size})
    return label, entries


def _patient_context(dataset, patient_relative):
    label, root = _dataset_root(dataset)
    if not patient_relative or '\\' in patient_relative or patient_relative.startswith('/'):
        raise ValueError('患者目录相对路径无效')
    patient = root.joinpath(*patient_relative.split('/')).resolve()
    try:
        patient.relative_to(root)
    except ValueError as exc:
        raise ValueError('患者目录路径越界') from exc
    if not patient.is_dir() or patient == root:
        raise ValueError('患者目录不存在或未选择具体患者')
    _, entries = _dataset_catalog(dataset, patient)
    sources = [root.joinpath(*entry['path'].split('/')) for entry in entries]
    return label, root, patient, entries, sources


def _patient_cache(dataset, patient_relative):
    _, _, patient, entries, sources = _patient_context(dataset, patient_relative)
    # All registered frames share the first frame's coordinates. Changing that
    # reference invalidates the whole cache, even when later files are unchanged.
    reference=sources[0].relative_to(patient).as_posix().encode('utf-8')+sources[0].read_bytes()
    key=hashlib.sha256(model_key(_REPO).encode('ascii')+reference).hexdigest()
    legacy=hashlib.sha256(legacy_model_key(_REPO).encode('ascii')+reference).hexdigest()
    return PatientCache(patient, sources, key, compatible_model_keys=(legacy,)), entries


def _state_versions(state):
    if state is None:
        return {}
    with state.lock:
        return {'source_revision': state.source_revision, 'results_revision': state.results_revision}


def _do_transfer(bin_bytes, index=0, filename="image.bin", mode=0, state=None,
                 stream_folder=None, stream_path=None):
    if int(index) != 0:
        return {'ok': False, 'log': '单帧网口传输的索引必须为 0'}
    return _display_job(bin_bytes, filename, mode, state, upload=True,
                        stream_folder=stream_folder, stream_path=stream_path)


def _do_render(mode, state=None):
    return _display_job(b'', state.image_name if state is not None else 'image.bin',
                        mode, state, upload=False)


def _display_job(bin_bytes, filename, mode, state, upload, stream_folder=None, stream_path=None):
    """Upload once; render other modes only after the preceding PC save completes."""
    global _DISPLAY_PENDING
    started = time.perf_counter()
    timings = {'transfer_ms': 0.0, 'readback_ms': 0.0, 'pc_files_ms': 0.0}
    def record_transfer(result, before):
        timings['transfer_ms'] += (time.perf_counter() - before) * 1000
        stages = result.get('timings_ms', {})
        timings['pc_files_ms'] += stages.get('save_ms', 0) + stages.get('preview_ms', 0)
    result_name = None
    readback = None
    try:
        _require_return_path(state)
        if upload:
            _validate_bin_frame(bin_bytes, filename)
        mode = int(mode)
        if mode not in range(6):
            raise ValueError("处理模式必须为 0..5（5 为全显示）")
        if stream_folder is not None:
            if mode == 5:
                raise ValueError('流模式不支持全显示')
            result_name = _stream_target(stream_folder, stream_path or '', filename)
    except Exception as exc:
        return {"ok": False, "log": str(exc)}
    if not _TRANSFER_LOCK.acquire(blocking=False):
        return {"ok": False, "log": "已有一帧正在传输，请等待完成"}
    results = []
    modes = list(range(5)) if mode == 5 else [mode]
    context = None
    try:
        _require_return_path(state)  # mode changes share _TRANSFER_LOCK
        key = (upload, hashlib.sha256(bin_bytes).digest(), filename, mode, result_name)
        if _DISPLAY_PENDING is not None:
            if _DISPLAY_PENDING['key'] != key:
                raise RuntimeError("上一任务的回传尚未确认，请使用相同原图和显示模式重试")
            context = _DISPLAY_PENDING
        else:
            context = {'key': key, 'results': [], 'uploaded': False, 'input_bytes': 0}
        results = context['results']
        if state is not None:
            if upload:
                state.replace_image(bin_bytes, filename, preserve_results=result_name is not None,
                                    display_name=stream_folder)
            with state.lock:
                state.processed_results.update({str(item['mode']): item for item in results})
                state.transfer_status = {'busy': True, 'completed': len(results), 'total': len(modes)}
        # Keep UART parameters fixed throughout upload, render and durable saves.
        with _serial_lock():
            if upload and not context['uploaded']:
                save_options = {'result_name': result_name} if result_name is not None else {}
                before = time.perf_counter()
                result = _FRAME_CLIENT.transfer(bin_bytes, filename, **save_options)
                record_transfer(result, before)
                context['uploaded'] = True
                context['input_bytes'] = FRAME_BYTES
                # The first return belongs to the NEW image in the current PL mode.
                if result['mode'] in modes:
                    results.append(result)
                    if state is not None:
                        state.publish_result(result, stream=result_name is not None)
                        with state.lock:
                            state.transfer_status.update(completed=len(results))
            completed = {item['mode'] for item in results}
            for current_mode in modes:
                if current_mode in completed:
                    continue
                if state is not None:
                    with state.lock:
                        state.transfer_status.update(mode=current_mode)
                save_options = {'result_name': result_name} if result_name is not None else {}
                before = time.perf_counter()
                result = _FRAME_CLIENT.render(current_mode, filename, **save_options)
                record_transfer(result, before)
                if not result['frames']:  # Board has no image yet; just configure it.
                    break
                results.append(result)
                if state is not None:
                    state.publish_result(result, stream=result_name is not None)
                    with state.lock:
                        state.transfer_status.update(completed=len(results))
                    state.log('模式 %d 回传已保存并确认: %s' % (current_mode, result['files']['bin']))
            if result_name is not None or (state is not None and state.system_mode == 'medical'):
                # Durable image jobs have no TCP status prefix. Continuous streams
                # use FramePipeline metadata and never enter this UART path.
                before = time.perf_counter()
                readback = _readback_regs()
                timings['readback_ms'] = (time.perf_counter() - before) * 1000
                if not readback['ok']:
                    raise RuntimeError('本帧 FPGA 状态回读失败: ' + readback['log'])
        _DISPLAY_PENDING = None
        results.sort(key=lambda item: item['mode'])
        timings['service_total_ms'] = (time.perf_counter() - started) * 1000
        return {'ok': True, 'frames': len(results), 'bytes': context['input_bytes'],
                'output_bytes': sum(item['output_bytes'] for item in results),
                'results': results, 'files': results[-1]['files'] if results else None,
                'readback': readback, 'timings_ms': timings, **_state_versions(state),
                'log': '\n'.join(item['log'] for item in results) or '显示模式已设置'}
    except TimeoutError as exc:
        _DISPLAY_PENDING = None
        _FRAME_CLIENT.pending = None
        if state is not None:
            with state.lock:
                state.transfer_status = {}
            state.log(str(exc))
        return {"ok": False, "timeout": True, "results": results, "log": str(exc), **_state_versions(state)}
    except Exception as exc:
        if context is not None:
            _DISPLAY_PENDING = context if (_FRAME_CLIENT.pending is not None or context['uploaded']) else None
        message = "%s: %s" % (type(exc).__name__, exc)
        if state is not None:
            state.log('处理失败: ' + message)
        return {"ok": False, "results": results, "log": message, **_state_versions(state)}
    finally:
        if state is not None and context is not None:
            with state.lock:
                state.transfer_status.update(busy=False)
        _TRANSFER_LOCK.release()


def customize_page(page):
    # The UART readback handler is installed once in TAIL_SCRIPT.
    page = page.replace(
        "document.getElementById('request').addEventListener('click',()=>fetch('/api/command?request=1'));", "")
    page = page.replace('serial:j.serial_connected?', 'network:j.serial_connected?')
    page = page.replace(
        '<button id="thresholdUpdate" type="button">阈值更新</button>',
        '<button id="thresholdUpdate" type="button" onclick="dshThrUpdate()">阈值更新</button>')
    page = page.replace(
        '<div id="metrics"',
        '<div id="dshReadback" data-system-mode="processing">'
        '<div class="metric"><span>掩膜面积</span><b id="dshRbLes">—</b></div>'
        '<div class="metric"><span>分割阈值</span><b id="dshRbThr">—</b></div>'
        '<div class="metric"><span>阈值模式</span><b id="dshRbMode">—</b></div>'
        '<div class="metric"><span>输出显示</span><b id="dshRbVid">—</b></div>'
        '<div class="metric"><span>掩膜透明度</span><b id="dshRbAlpha">—</b></div>'
        '<div class="metric" data-medical-fps><span>帧率</span><b><span id="dshGuiFps">—</span> <span class="unit">FPS</span></b></div>'
        '</div><div id="metrics"')
    return page.replace('</body>', TAIL_SCRIPT + '</body>')


class NetworkHandler(web_common.Handler):

    def _send_html(self,page):
        body=page.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Cache-Control','no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma','no-cache')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _startup_get(self,parsed):
        if parsed.path=='/api/startup/check':
            if getattr(self.server,'flash_state',{}).get('state')=='running':
                self.send_json({'ok':False,'error':'烧录期间不能重复检查设备'},status=409);return True
            result=_probe_startup(self.server.startup_config)
            self.server.startup_last_check=result
            self.send_json(result);return True
        if parsed.path=='/api/startup/status':
            with self.server.flash_lock:
                status={**self.server.flash_state,'ready':self.server.flash_ready}
            self.send_json(status);return True
        if parsed.path=='/':
            if self.server.flash_ready:
                self.send_response(302);self.send_header('Location','/console');self.end_headers();return True
            self._send_html(STARTUP_PAGE);return True
        if parsed.path=='/console':
            if not self.server.flash_ready:
                self.send_response(302);self.send_header('Location','/');self.end_headers();return True
            self._send_html(web_common.HTML_PAGE);return True
        return False

    def _startup_blocks(self,parsed):
        if parsed.path.startswith('/api/') and not self.server.flash_ready:
            self.send_json({'ok':False,'startup_required':True,
                'error':'请先在启动页完成设备检查和烧录'},status=423)
            return True
        return False

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path=='/api/startup/flash':
            with self.server.flash_lock:
                if self.server.flash_ready:
                    self.send_json({'ok':True,'state':'complete'});return
                if self.server.flash_state.get('state')=='running':
                    self.send_json({'ok':True,'state':'running'});return
                checked=self.server.startup_last_check
                if not checked or not checked.get('ready'):
                    self.send_json({'ok':False,'error':'设备检查尚未全部通过，请先重新检查连接'},status=409);return
                if time.time()-checked.get('checked_at',0)>180:
                    self.send_json({'ok':False,'error':'连接检查已过期，请重新检查设备'},status=409);return
                self.server.flash_state={'state':'running','progress':2,'phase':'准备烧录',
                    'message':'启动 scripts/flash_current.sh init…','error':''}
            threading.Thread(target=_flash_current_worker,args=(self.server,),
                             name='heartcare-flash',daemon=True).start()
            self.send_json({'ok':True,'state':'running'});return
        if self._startup_blocks(parsed):return
        if parsed.path == '/api/network/medical/clear':
            cache=None;locked=False
            try:
                size=int(self.headers.get('Content-Length','0'))
                if not 0<size<=4096:raise ValueError('无效的清除请求')
                options=json.loads(self.rfile.read(size))
                if not isinstance(options,dict) or options.get('confirm') is not True:
                    raise ValueError('清除分割结果必须先确认')
                locked=_TRANSFER_LOCK.acquire(blocking=False)
                if not locked:raise ValueError('请先停止流并等待当前帧完成后再清除分割结果')
                cache,_=_patient_cache(options.get('dataset',''),options.get('patient',''))
                cache.clear()
                self.send_json({'ok':True,**cache.status()})
            except Exception as error:self.send_json({'ok':False,'error':str(error)},status=400)
            finally:
                if cache is not None:cache.close()
                if locked:_TRANSFER_LOCK.release()
            return
        if parsed.path.startswith('/api/network/stream/'):
            self.stream_request(parsed)
            return
        if parsed.path == '/api/network/frame':
            self.receive_stream_frame(parsed)
            return
        if parsed.path not in ('/api/network/transfer', '/api/serial/transfer', '/api/image'):
            super().do_POST()
            return
        try:
            query = parse_qs(parsed.query)
            filename = query.get('name', [''])[0]
            stream = query.get('stream', ['0'])[0] == '1'
            folder = query.get('folder', [''])[0] if stream else None
            relative = query.get('path', [''])[0] if stream else None
            if stream:
                _stream_target(folder, relative, filename)
            if Path(filename).suffix.lower() != '.bin':
                raise ValueError('仅支持 256x256x8-bit 的 .bin 文件')
            n = int(self.headers.get('Content-Length', '0'))
            if n != FRAME_BYTES:
                raise ValueError('BIN 必须恰好为 65536 字节')
            data = self.rfile.read(n)
            _validate_bin_frame(data, filename)
            if parsed.path == '/api/image':
                if not _TRANSFER_LOCK.acquire(blocking=False):
                    raise RuntimeError('正在处理图像，请等待回传完成后再选择原图')
                try:
                    if _DISPLAY_PENDING is not None:
                        old = _DISPLAY_PENDING['key']
                        if not old[0] or old[1:3] != (hashlib.sha256(data).digest(), filename):
                            raise RuntimeError('上一任务尚未完成，请先用原来的图像和显示模式恢复回传')
                        if old[4] != (_stream_target(folder, relative, filename) if stream else None):
                            raise RuntimeError('上一任务的结果目录尚未确认，请先恢复原任务')
                    self.state.replace_image(data, filename, preserve_results=stream, display_name=folder)
                finally:
                    _TRANSFER_LOCK.release()
                extra = self.state.original_snapshot()
                self.send_json({'ok': True, 'name': self.state.image_name, **extra})
            else:
                index = query.get('index', ['0'])[0]
                mode = query.get('mode', ['0'])[0]
                extra = {'stream_folder': folder, 'stream_path': relative} if stream else {}
                self.send_json(_do_transfer(data, index, filename=filename, mode=mode, state=self.state, **extra))
        except Exception as exc:
            message = '%s: %s' % (type(exc).__name__, exc)
            self.send_json({'ok': False, 'log': message, 'error': message}, status=400)

    control_worker = None

    def stream_request(self, parsed):
        """Feed the bounded Python sender independently of result delivery."""
        try:
            action = parsed.path.rsplit('/', 1)[-1]
            if action in ('start', 'control'):
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 4096:
                    raise ValueError('invalid stream control length')
                options = json.loads(self.rfile.read(size))
                if not isinstance(options, dict):
                    raise ValueError('invalid stream control')
                if action == 'start':
                    token, session = self.server.start_stream(self.state, options)
                else:
                    token = options.get('session', '')
                    session = self.server.get_stream(token)
                    session.control(options.get('action'), mode=options.get('mode'))
                self.send_json({'ok': True, 'session': token, **session.snapshot()})
                return
            if action != 'enqueue':
                self.send_json({'ok': False, 'error': 'unknown stream endpoint'}, status=404)
                return
            size = int(self.headers.get('Content-Length', '0'))
            # Consume a bounded submitted frame before reporting query errors.
            # Closing with unread upload bytes can reset HTTP on Windows.
            data = self.rfile.read(size) if 0 <= size <= FRAME_BYTES else b''
            if size != FRAME_BYTES:
                raise ValueError('BIN 必须恰好为 65536 字节')
            query = parse_qs(parsed.query)
            token = query.get('session', [''])[0]
            session = self.server.get_stream(token)
            filename = query.get('name', [''])[0]
            relative = query.get('path', [''])[0]
            _stream_target(session.folder, relative, filename)
            _validate_bin_frame(data, filename)
            frame = {'data': data, 'name': filename, 'path': relative,
                     'index': int(query.get('index', ['-1'])[0]),
                     'sequence': int(query.get('sequence', ['-1'])[0])}
            if frame['index'] < 0:
                raise ValueError('stream frame index must be nonnegative')
            status = session.enqueue(frame)
            self.send_json({'ok': True, **status})
        except QueueFull as error:
            self.send_json({'ok': False, 'full': True, 'error': str(error)}, status=409)
        except Exception as error:
            self.send_json({'ok': False, 'error': str(error), 'log': str(error)}, status=400)

    def stream_result(self, parsed):
        started = time.perf_counter()
        try:
            token = parse_qs(parsed.query).get('session', [''])[0]
            session = self.server.get_stream(token)
            result = session.take_result(timeout=1)
            received = time.perf_counter()
            status = session.snapshot()
            if result is None:
                expected=getattr(session,'expected_total',None)
                if (expected is not None and status['completed']>=expected and
                    not status['busy'] and not status['pending'] and not status['stopped']):
                    # The final preview HTTP response may have been lost after
                    # dequeue. Disk commits and board completion remain valid.
                    session.control('stop')
                    self.send_json({'ok':True,'finished':True,**session.snapshot()})
                    return
                if status['stopped']:
                    self.send_json({'ok': not bool(status['error']), **status})
                else:
                    self.send_response(204)
                    self.send_header('Content-Length', '0')
                    self.send_header('Cache-Control', 'no-store')
                    self.end_headers()
                return
            frame = result['source']
            metadata = {key: value for key, value in result.items()
                        if key not in ('raw', 'source')}
            metadata['stream'] = {**status, 'index': frame['index'],
                                  'sequence': frame['sequence'],
                                  'completed': result['completed'],
                                  'frame_ms': result['frame_ms'],
                                  'completed_at': result['completed_at']}
            header = json.dumps(metadata, ensure_ascii=False).encode('utf-8')
            body = struct.pack('!I', len(header)) + header + frame['data'] + result['raw']
        except Exception as error:
            self.send_json({'ok': False, 'error': str(error)}, status=400)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Server-Timing', 'handler;dur=%.3f, preview_wait;dur=%.3f' %
                         ((time.perf_counter()-started)*1000, (received-started)*1000))
        self.end_headers()
        self.wfile.write(body)

    def receive_stream_frame(self, parsed):
        """Binary HTTP: BE JSON length, metadata, RGBA; HTTP timings in Server-Timing."""
        handler_started = time.perf_counter()
        acquired = False
        try:
            size = int(self.headers.get('Content-Length', '0'))
            body_started = time.perf_counter()
            data = self.rfile.read(size) if 0 <= size <= FRAME_BYTES else b''
            body_finished = time.perf_counter()
            if size != FRAME_BYTES:
                raise ValueError('BIN 必须恰好为 65536 字节')
            query = parse_qs(parsed.query)
            filename = query.get('name', [''])[0]
            folder, relative = query.get('folder', [''])[0], query.get('path', [''])[0]
            _stream_target(folder, relative, filename)
            mode = int(query.get('mode', ['0'])[0])
            if mode not in range(5):
                raise ValueError('流模式必须为 0..4')
            _validate_bin_frame(data, filename)
            if not _TRANSFER_LOCK.acquire(blocking=False):
                raise RuntimeError('another FPGA frame is in progress')
            acquired = True
            _require_return_path(self.state)
            if _DISPLAY_PENDING is not None:
                raise RuntimeError('上一单图任务尚未完成，请先恢复原任务')
            started = time.perf_counter()
            self.state.replace_image(data, filename, preserve_results=True, display_name=folder)
            network_started = time.perf_counter()
            with _serial_lock():
                result = _FRAME_CLIENT.receive_frame(data)
                elapsed = result['timings_ms']['transfer_ms']
                if result['mode'] != mode:
                    result = _FRAME_CLIENT.receive_frame(mode=mode)
                    elapsed += result['timings_ms']['transfer_ms']
            network_finished = time.perf_counter()
            raw = result['raw']
            metadata = {key: value for key, value in result.items() if key != 'raw'}
            metadata['timings_ms'].update(transfer_ms=elapsed,
                service_total_ms=(time.perf_counter() - started)*1000)
            self.state.publish_result(metadata, stream=True)
            metadata.update(_state_versions(self.state))
            publish_finished = time.perf_counter()
            header = json.dumps(metadata, ensure_ascii=False).encode('utf-8')
            body = struct.pack('!I', len(header)) + header + raw
            packed = time.perf_counter()
            server_timings = {'handler': (packed-handler_started)*1000,
                              'body': (body_finished-body_started)*1000,
                              'source': (network_started-body_finished)*1000,
                              'board': (network_finished-network_started)*1000,
                              'publish': (publish_finished-network_finished)*1000,
                              'pack': (packed-publish_finished)*1000}
        except Exception as error:
            self.send_json({'ok': False, 'error': str(error), 'log': str(error),
                            'timeout': isinstance(error, TimeoutError)}, status=400)
            return
        finally:
            if acquired:
                _TRANSFER_LOCK.release()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Server-Timing', ', '.join('%s;dur=%.3f' % pair for pair in server_timings.items()))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if self._startup_get(parsed):return
        if self._startup_blocks(parsed):return
        if parsed.path == '/api/serial/source_fps':
            self.send_json(_set_source_fps(parse_qs(parsed.query).get('value',[''])[0]))
            return
        if parsed.path == '/api/system_mode':
            mode = parse_qs(parsed.query).get('mode', [''])[0]
            if mode not in ('simulation', 'processing', 'medical'):
                self.send_json({'ok': False, 'error': 'unsupported system mode'}, status=400)
                return
            if not _TRANSFER_LOCK.acquire(blocking=False):
                self.send_json({'ok': False, 'error': '请先停止流或等待当前图像任务完成，再切换系统模式'}, status=409)
                return
            try:
                if _DISPLAY_PENDING is not None or _FRAME_CLIENT.pending is not None:
                    raise RuntimeError('上一帧回传尚未完成，请先完成原任务再切换模式')
                extra = {}
                if mode != 'simulation':
                    extra = _set_system_mode(1 if mode == 'medical' else 0)
                    if not extra['ok']:
                        raise RuntimeError(extra['log'])
                _FRAME_CLIENT.timeout = 300 if mode == 'medical' else 60
                # Commit GUI state only after the matching PL MODE readback.
                with self.state.lock:
                    self.state.simulate = mode == 'simulation'
                    self.state.system_mode = mode
                self.send_json({**extra, 'ok': True, 'simulate': mode == 'simulation',
                                'system_mode': mode})
            except Exception as error:
                self.send_json({'ok': False, 'error': str(error)}, status=400)
            finally:
                _TRANSFER_LOCK.release()
            return
        if parsed.path == '/api/network/stream/datasets':
            try:
                dataset = parse_qs(parsed.query).get('dataset', [''])[0]
                label, root, selected = _choose_dataset_folder(dataset)
                if selected is None:
                    self.send_json({'ok': False, 'cancelled': True, 'dataset': dataset})
                    return
                _, entries = _dataset_catalog(dataset, selected)
                self.send_json({'ok': True, 'dataset': dataset, 'folder': selected.name,
                                'patient': selected.relative_to(root).as_posix(),
                                'count': len(entries), 'files': entries})
            except Exception as error:
                self.send_json({'ok': False, 'error': str(error), 'log': str(error)}, status=400)
            return
        if parsed.path == '/api/network/medical/cache':
            cache = None
            try:
                query = parse_qs(parsed.query)
                dataset = query.get('dataset', [''])[0]
                patient = query.get('patient', [''])[0]
                cache, entries = _patient_cache(dataset, patient)
                status = cache.status()
                status.update(dataset=dataset, patient=patient, count=len(entries))
                self.send_json({'ok': True, **status})
            except Exception as error:
                self.send_json({'ok': False, 'error': str(error)}, status=400)
            finally:
                if cache is not None:
                    cache.close()
            return
        if parsed.path == '/api/network/stream/dataset-frame':
            try:
                query = parse_qs(parsed.query)
                dataset = query.get('dataset', [''])[0]
                relative = query.get('path', [''])[0]
                _, path = _dataset_file(dataset, relative)
                data = path.read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.end_headers()
                self.wfile.write(data)
            except Exception as error:
                self.send_json({'ok': False, 'error': str(error), 'log': str(error)}, status=400)
            return
        if parsed.path == '/api/network/stream/result':
            self.stream_result(parsed)
            return
        if parsed.path == '/api/network/state':
            state = self.state.snapshot(0, 128, 255, 50, include_images=False)
            if self.server.stream is not None:
                state['stream'] = self.server.stream.snapshot()
            self.send_json(state)
            return
        if parsed.path == '/api/network/render':
            query = parse_qs(parsed.query)
            self.send_json(_do_render(query.get('mode', ['0'])[0], self.state))
            return
        if parsed.path == '/api/command':
            query = web_common.parse_qs(parsed.query)
            if 'threshold' in query:
                value = int(query['threshold'][0])
                self.server.threshold = value
                if self.control_worker is not None:
                    self.control_worker.write(proto.encode_set_threshold(value))
            if 'plmode' in query:
                value = int(query['plmode'][0])
                self.server.pl_mode = value
                if self.control_worker is not None:
                    self.control_worker.write(proto.encode_set_mode(value))
            if 'request' in query and self.control_worker is not None:
                self.control_worker.write(proto.encode_request_status())
            if 'mode' in query:
                # mode is the local display mode; do not write PL MODE_REG.
                pass
            self.send_json({'ok': True})
            return
        if parsed.path == '/api/serial/readback':
            self.send_json(_readback_regs())
            return
        if parsed.path == '/api/serial/threshold':
            try:
                _q = parse_qs(parsed.query)
                self.send_json(_do_threshold(int(_q.get('mode', ['0'])[0]),
                                             int(_q.get('value', ['128'])[0])))
            except Exception as exc:
                self.send_json({'ok': False, 'log': '%s: %s' % (type(exc).__name__, exc)})
            return
        if parsed.path == '/api/serial/threshold':
            try:
                _q = parse_qs(parsed.query)
                self.send_json(_do_threshold(int(_q.get('mode', ['0'])[0]), int(_q.get('value', ['128'])[0])))
            except Exception as exc:
                self.send_json({'ok': False, 'log': '%s: %s' % (type(exc).__name__, exc)})
            return
        if parsed.path == '/api/serial/readback':
            self.send_json(_readback_regs())
            return
        if parsed.path == '/api/serial/video_mode':
            try:
                _q = parse_qs(parsed.query)
                self.send_json(_set_video_mode(_q.get('mode', ['0'])[0]))
            except Exception as exc:
                self.send_json({'ok': False, 'log': '%s: %s' % (type(exc).__name__, exc)})
            return
        if parsed.path == '/api/serial/mask_transparency':
            query = parse_qs(parsed.query)
            self.send_json(_set_mask_transparency(query.get('value', [''])[0]))
            return
        if parsed.path == '/api/serial/hdmi_enable':
            query = parse_qs(parsed.query)
            self.send_json(_set_hdmi_enable(query.get('value', [''])[0]))
            return
        super().do_GET()



class NetworkServer(web_common.ThreadingHTTPServer):
    daemon_threads = True
    # Concurrent preview, control and result polling can otherwise overflow
    # Windows' small default accept backlog during a brief scheduling stall.
    request_queue_size = 64

    def __init__(self, *args, **kwargs):
        self.stream_lock = threading.Lock()
        self.stream = None
        self.stream_token = None
        self.flash_lock=threading.Lock()
        self.flash_ready=False
        self.flash_state={'state':'idle','progress':0,'phase':'等待烧录','message':'','error':''}
        self.startup_last_check=None
        super().__init__(*args, **kwargs)

    def get_stream(self, token):
        with self.stream_lock:
            if not token or self.stream is None or token != self.stream_token:
                raise ValueError('流会话已失效，请重新选择流文件夹')
            return self.stream

    def start_stream(self, state, options):
        _require_return_path(state)
        folder = options.get('folder', '')
        _stream_target(folder, 'frame.bin', 'frame.bin')
        mode = int(options.get('mode', 0))
        if mode not in range(5):
            raise ValueError('流模式必须为 0..4')
        source_fps=int(options.get('source_fps',30))
        if not 1<=source_fps<=100:raise ValueError('源视频 FPS 必须为 1..100')
        source_us=round(1000000/source_fps)
        workflow=options.get('workflow')
        if workflow not in (None, 'segmentation', 'analysis'):
            raise ValueError('未知医学流任务')
        if workflow and state.system_mode != 'medical':
            raise ValueError('模型分割和流分析只能在医学分析模式运行')
        dataset=patient_relative=None
        cache=None;patient_entries=[];patient_prefix='';cache_status={}
        if workflow:
            dataset=options.get('dataset','');patient_relative=options.get('patient','')
            cache, patient_entries = _patient_cache(dataset, patient_relative)
            cache_status=cache.status()
            if workflow=='analysis' and not cache_status['complete']:
                cache.close()
                raise ValueError('该患者尚未完成全部 U-Net 模型分割')
            _, root, patient, _, _ = _patient_context(dataset, patient_relative)
            patient_prefix=patient.relative_to(root).as_posix()
            patient_order={name:index for index,name in enumerate(cache.sources)}
        token = secrets.token_hex(16)
        with self.stream_lock:
            if not _TRANSFER_LOCK.acquire(blocking=False):
                if cache is not None:cache.close()
                raise RuntimeError('已有图像或流正在传输，请先停止当前任务')
            try:
                _require_return_path(state)
                if _DISPLAY_PENDING is not None or _FRAME_CLIENT.pending is not None:
                    raise RuntimeError('上一图像任务尚未完成，请先恢复原任务')
                client = _FRAME_CLIENT
                # Stream owns a separate full-duplex socket. Close an idle old
                # transaction socket so it cannot later resume a stale session.
                client.close()
                # Cover four input slots, three output slots and TCP transit;
                # a four-job cap would throttle while board input slots are free.
                # Bound upload bursts while the GEM is also transmitting results.
                # On this Windows/board pair, 3 KiB batches eliminated RX overruns
                # and retransmission timeouts in a 1000-frame full-duplex run.
                medical = state.system_mode == 'medical'
                pipeline = FramePipeline(client.host, client.port, 300 if medical else client.timeout,
                                         capacity=(8 if workflow=='analysis' else 1 if medical else 8),
                                         send_chunk=3072, send_pause=.0001,
                                         source_frame_us=source_us, medical_workflow=workflow)
                if workflow == 'segmentation':
                    pipeline=SegmentationPipeline(pipeline,cache,patient_prefix,
                        alpha=lambda:int(options.get('mask_transparency',45)),
                        resume_reference=next(iter(cache.sources.values())).read_bytes() if cache_status['completed'] else None)
                elif workflow == 'analysis':
                    pipeline=AnalysisPipeline(pipeline,cache,patient_prefix)
                curves=MedicalCurveHistory()

                def publish(source, result):
                    started = time.perf_counter()
                    curve_source=source
                    if workflow and patient_prefix and source.get('path','').startswith(patient_prefix+'/'):
                        relative=source['path'][len(patient_prefix)+1:]
                        curve_source={**source,'source_index':patient_order.get(relative,source.get('index')),
                                      'source_path':relative}
                    curves.observe(result.get('readback',{}),curve_source)
                    state.replace_image(source['data'], source['name'],
                                        preserve_results=True, display_name=folder)
                    state.publish_result({key: value for key, value in result.items() if key != 'raw'},
                                         stream=True)
                    result.update(_state_versions(state))
                    result['timings_ms']['publish_ms'] = (time.perf_counter()-started)*1000

                def release():
                    try:
                        pipeline.close()
                        pending, client.pending = client.pending, None
                        if pending is not None:
                            client._cancel_job(pending['job'])
                    finally:
                        _TRANSFER_LOCK.release()

                session = QueuedStream(None, release, mode=mode, pipeline=pipeline, on_result=publish)
                session.folder = folder
                session.workflow = workflow
                session.expected_total=(cache_status['total']-cache_status['completed']) if workflow=='segmentation' else None
                session.patient = patient_relative
                self.stream = session
                self.stream_token = token
                return self.stream_token, session
            except BaseException:
                if cache is not None:
                    try:cache.close()
                    except Exception:pass
                _TRANSFER_LOCK.release()
                raise

    def server_close(self):
        if self.stream is not None:
            self.stream.close(timeout=65)
        super().server_close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--board-ip', default='192.168.1.10')
    parser.add_argument('--control-port', type=int, default=5000)
    parser.add_argument('--image-port', type=int, default=5001)
    parser.add_argument('--legacy-tcp-control',action='store_true',
                        help='Use the separate legacy/mock TCP control service on port 5000')
    parser.add_argument('--transfer-ip', default='192.168.1.10')
    parser.add_argument('--transfer-port', type=int, default=5002)
    parser.add_argument('--serial-port', default=_os.environ.get('SERIAL_PORT','COM7'))
    parser.add_argument('--result-dir', default='E:/fpga_done_img')
    parser.add_argument('--image', default=r'C:/Users/13995/Desktop/fpga校赛/camus_processed/images/training/patient0001/patient0001_4CH_ED.png')
    parser.add_argument('--simulate', action='store_true')
    parser.add_argument('--simulate-image', action='store_true')
    parser.add_argument('--threshold', type=int, default=128)
    parser.add_argument('--pl-mode', type=int, default=1, choices=[1, 2])
    parser.add_argument('--upload-on-start', action='store_true')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()
    global _SERIAL_PORT
    _SERIAL_PORT=args.serial_port
    global _FRAME_CLIENT
    _FRAME_CLIENT = FrameTransferClient(args.transfer_ip, args.transfer_port, args.result_dir)

    web_common.HTML_PAGE = customize_page(web_common.HTML_PAGE)
    state = web_common.WebState(args.image, args.simulate)
    simulator = web_common.WebSimulator(state, args.simulate_image)
    image_sender = TcpImageSender(args.board_ip, args.image_port)
    control_worker = (TcpControlWorker(state,args.board_ip,args.control_port)
                      if args.legacy_tcp_control and not args.simulate else None)
    if control_worker is not None:
        control_worker.start()

    web_common.Handler.state = state
    web_common.Handler.simulator = simulator
    web_common.Handler.serial_worker = control_worker
    NetworkHandler.control_worker = control_worker

    if args.upload_on_start:
        try:
            result = image_sender.send_file(args.image, 1)
            if control_worker is not None:
                control_worker.write(proto.encode_set_threshold(args.threshold))
                control_worker.write(proto.encode_set_mode(args.pl_mode))
                control_worker.write(proto.encode_start_analyze())
            state.log(f"启动上传并启动分析: {result['elapsed_ms']:.2f} ms")
        except Exception as exc:
            state.log(f'启动上传失败: {exc}')

    def background():
        while True:
            if state.simulate:
                simulator.tick()
            time.sleep(0.1)

    threading.Thread(target=background, daemon=True).start()
    server = NetworkServer((args.host, args.port), NetworkHandler)
    server.startup_config={'repo':str(_REPO),'board_ip':args.transfer_ip,
        'control_port':args.control_port,'image_port':args.image_port,
        'transfer_port':args.transfer_port,'serial_port':args.serial_port}
    server.image_path = args.image
    server.threshold = args.threshold
    server.pl_mode = args.pl_mode
    url = f'http://{args.host}:{args.port}/'
    state.log('网络监控服务已启动: ' + url)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if control_worker is not None:
            control_worker.stop()
        server.server_close()
        _FRAME_CLIENT.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
