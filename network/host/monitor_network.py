#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
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
sys.path.insert(0, str(ROOT))
import protocol as proto
import web_common
from frame_transfer import FrameTransferClient, normalize_result_name


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
let dshStreamMode = false;
let dshStreamRunning = false;
let dshFastStream = false, dshStreamWorker = null, dshPreviewGeneration = 0;
let dshFpsPaused = false;
let dshStreamFiles = [], dshStreamIndex = 0, dshStreamFolder = '';
let dshStreamSignature = '', dshStreamQueue = [];
let dshStreamSamples = [], dshStreamCompleted = 0;
const dshNow = () => typeof performance !== 'undefined' ? performance.now() : Date.now();
function dshResetPerformance(resetFps = false) {
    if (resetFps) { dshStreamSamples = []; resetFrameRate(); }
    dshStreamCompleted = 0;
  document.getElementById('streamPerformance').hidden = false;
  document.getElementById('streamFps').textContent = '等待首帧回传…';
  document.getElementById('streamFrameTime').textContent = '';
  document.getElementById('streamTiming').textContent = '';
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
  const controls = ['imageFile', 'chooseImage', 'chooseStream', 'streamFolder', 'fpgaOutputMode', 'thresholdMode',
    'threshold', 'thresholdUpdate', 'maskOpacity', 'maskOpacityUpdate', 'request'];
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
  const mode = document.getElementById('fpgaOutputMode').value;
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
function dshApplyReadback(j) {
    if (!j.ok) throw new Error('状态回读失败: ' + j.log);
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
    lastConfirmedVideoMode = j.video_mode;
    if (!dshStreamMode && !dshTransferBusy && document.getElementById('fpgaOutputMode').value !== '5')
      document.getElementById('fpgaOutputMode').value = j.video_mode;
    if (!dshStreamMode) {
      document.getElementById('maskOpacity').value = j.mask_transparency;
      document.getElementById('maskOpacityValue').textContent = j.mask_transparency;
    }
    updateOverlayControls();
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
    if (document.getElementById('systemMode').value === 'processing') await dshProcess(true);
  });
});
let lastConfirmedVideoMode = 0;
document.getElementById('fpgaOutputMode').addEventListener('change', async e => {
  if (dshStreamMode) {
    if(dshStreamWorker)dshStreamWorker.postMessage({type:'mode',mode:e.target.value});
    return; // The next input frame carries the requested mode.
  }
  await dshRun(async () => {
    const message = await dshProcess(false); await dshReadback(); return message;
  });
});
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

function dshStreamControls() {
  const stopping = !dshStreamRunning && dshTransferBusy;
  document.getElementById('chooseImage').disabled = dshStreamRunning || dshTransferBusy;
  document.getElementById('chooseStream').textContent = dshStreamRunning ? '停止流' : '选择流文件夹';
  document.getElementById('chooseStream').disabled = !dshStreamRunning && dshTransferBusy;
  for (const id of ['fpgaOutputMode', 'thresholdUpdate', 'maskOpacity', 'maskOpacityUpdate', 'request'])
    document.getElementById(id).disabled = stopping;
  document.getElementById('fullDisplayOption').disabled = dshStreamMode;
  updateModeMenu(); updateThresholdControls(); updatePreviewLayout();
}
function dshStopStream() {
  dshStreamRunning = false; // Let the current frame finish; never truncate MM2S.
  if(dshStreamWorker)dshStreamWorker.postMessage({type:'stop'});
    dshFpsPaused = true; dshStreamSamples = []; resetFrameRate(true); dshUpdateStreamFps();
  dshStreamControls();
  document.getElementById('chooseStream').disabled = true;
  document.getElementById('chooseStream').textContent = '等待当前帧完成…';
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
  document.getElementById('streamTiming').textContent=
    '收发 '+t.transfer_ms.toFixed(1)+' ms · 板端收包 '+(p.receive||0).toFixed(1)+
    ' ms · 准备 '+(p.setup||0).toFixed(1)+' ms · PL→DDR '+(p.pl_to_ddr||0).toFixed(1)+' ms';
  const interval=metadata.readback.pl_interval;
  if(interval&&interval.sequence)document.getElementById('streamTiming').textContent+=
    ' · 回传启动→下一帧写满 '+interval.elapsed_ms.toFixed(2)+' ms'+
    '（写端反压 '+interval.write_stall_ms.toFixed(2)+' ms）';
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
function dshRunStreamWorker(entries,streamChanged) {
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
        document.getElementById('comparisonProcessedLabel').textContent=streamModeLabels[result.mode];
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
          processed=message;processed.queuedAt=dshNow();dshApplyFastStats(message);dshApplyReadback(message.metadata.readback);
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
    worker.postMessage({type:'start',files:entries,index:dshStreamIndex,folder:dshStreamFolder,
      mode:document.getElementById('fpgaOutputMode').value,times:dshStreamSamples.map(t=>t+offset)});
  });
}
async function dshStartStream(files) {
  if (dshTransferBusy || dshStreamRunning || systemModePending) return;
  let performanceStarted = false;
  dshTransferBusy = true;
  dshStreamControls();
  try {
    const entries = Array.from(files).filter(file => file.name.toLowerCase().endsWith('.bin')).map(file => {
      dshValidateBin(file);
      const parts = file.webkitRelativePath.split('/');
      const folder = parts.shift(), path = parts.join('/');
      if (!folder || !path) throw new Error('请选择包含 BIN 图像的文件夹');
      return {file, folder, path};
    });
    if (!entries.length) throw new Error('所选文件夹没有 BIN 图像');
    const folder = entries[0].folder;
    if (entries.some(entry => entry.folder !== folder)) throw new Error('一次只能选择一个流文件夹');
    entries.sort((a,b) => a.path.localeCompare(b.path, 'zh-CN', {numeric:true, sensitivity:'base'}));
    const signature = folder + '\n' + entries.map(entry => entry.path).join('\n');
    const streamChanged = signature !== dshStreamSignature;
    if (streamChanged) dshStreamIndex = 0;
    dshStreamSignature = signature; dshStreamFolder = folder; dshStreamFiles = entries;
    if (document.getElementById('systemMode').value !== 'processing') {
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
    dshResetPerformance(streamChanged);
    performanceStarted = true;
    await dshRunStreamWorker(entries,streamChanged);
  } catch (error) { alert('流处理失败: ' + error.message); }
  finally {
    dshStreamRunning = false; dshTransferBusy = false;
    if (performanceStarted) document.getElementById('streamFrameTime').textContent +=
      (dshStreamCompleted ? ' · 已停止' : '已停止 · 已回传 0 帧');
    for (const request of dshStreamQueue.splice(0)) request.reject(new Error('流已停止，参数尚未更新'));
    document.getElementById('processingStatus').textContent = '';
    dshStreamControls();
  }
}
document.getElementById('chooseStream').addEventListener('click', () => {
  if (dshStreamRunning) { dshStopStream(); return; }
  if (dshTransferBusy) return;
  const picker = document.getElementById('streamFolder'); picker.value = ''; picker.click();
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
FRAME_DONE_LINE = "RESULT: FRAME_DONE frames=1 bytes=65536"
_SERIAL_LOCK = threading.RLock()
_TRANSFER_LOCK = threading.Lock()
_FRAME_CLIENT = FrameTransferClient()
_DISPLAY_PENDING = None


def _serial_lock():
    return _SERIAL_LOCK
# CAMUS 数据集 letterbox 之后每个像素代表的面积 (source: camus_pipeline/convert_camus.py:64)
PIXEL_AREA_MM2 = 0.436280886141

# WORD indices. PS multiplies these by 4 for aligned MMIO; UART labels use indices.
PL_REGISTERS = {"MODE": 0x00, "CMD_REG": 0x01, "VIDEO_MODE": 0x02,
                "STATUS": 0x03, "DATA_REG": 0x20, "LESION": 0x21,
                "MASK_TRANSP": 0x22}


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
        if name in PL_REGISTERS:
            if int(address, 16) != PL_REGISTERS[name]:
                raise ValueError("register map mismatch for %s; rebuild/flash matching PS and PL" % name)
            values[name] = int(value)
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
        return {"ok": True, "mode": regs["CMD_REG"], "system_mode": regs["MODE"],
                "threshold": regs["DATA_REG"], "actual_threshold": regs["STATUS"],
                "video_mode": regs["VIDEO_MODE"], "lesion_pixels": lesion,
                "mask_transparency": regs["MASK_TRANSP"],
                "lesion_mm2": "%.3f" % (lesion * PIXEL_AREA_MM2), "log": txt}
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


def _set_mask_transparency(value):
    result = _write_byte_register(b"P", value, "MASK_TRANSP", 100)
    if result["ok"]:
        result["mask_transparency"] = result["value"]
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
            if result_name is not None:
                # No next input frame until both the fresh return and R complete.
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
        '<div class="metric"><span>帧率</span><b><span id="dshGuiFps">—</span> <span class="unit">FPS</span></b></div>'
        '</div><div id="metrics"')
    return page.replace('</body>', TAIL_SCRIPT + '</body>')


class NetworkHandler(web_common.Handler):

    def do_POST(self):
        parsed = urlparse(self.path)
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

    def receive_stream_frame(self, parsed):
        """Binary HTTP response: BE JSON length, metadata JSON, then owned RGB/mode BIN."""
        acquired = False
        try:
            query = parse_qs(parsed.query)
            filename = query.get('name', [''])[0]
            folder, relative = query.get('folder', [''])[0], query.get('path', [''])[0]
            _stream_target(folder, relative, filename)
            mode = int(query.get('mode', ['0'])[0])
            if mode not in range(5):
                raise ValueError('流模式必须为 0..4')
            if int(self.headers.get('Content-Length', '0')) != FRAME_BYTES:
                raise ValueError('BIN 必须恰好为 65536 字节')
            data = self.rfile.read(FRAME_BYTES)
            _validate_bin_frame(data, filename)
            if not _TRANSFER_LOCK.acquire(blocking=False):
                raise RuntimeError('another FPGA frame is in progress')
            acquired = True
            if _DISPLAY_PENDING is not None:
                raise RuntimeError('上一单图任务尚未完成，请先恢复原任务')
            started = time.perf_counter()
            self.state.replace_image(data, filename, preserve_results=True, display_name=folder)
            with _serial_lock():
                result = _FRAME_CLIENT.receive_frame(data)
                elapsed = result['timings_ms']['transfer_ms']
                if result['mode'] != mode:
                    result = _FRAME_CLIENT.receive_frame(mode=mode)
                    elapsed += result['timings_ms']['transfer_ms']
            raw = result['raw']
            metadata = {key: value for key, value in result.items() if key != 'raw'}
            metadata['timings_ms'].update(transfer_ms=elapsed,
                service_total_ms=(time.perf_counter() - started)*1000)
            self.state.publish_result(metadata, stream=True)
            metadata.update(_state_versions(self.state))
            header = json.dumps(metadata, ensure_ascii=False).encode('utf-8')
            body = struct.pack('!I', len(header)) + header + raw
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
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == '/api/network/state':
            state = self.state.snapshot(0, 128, 255, 50, include_images=False)
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
        super().do_GET()



class NetworkServer(web_common.ThreadingHTTPServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--board-ip', default='192.168.1.10')
    parser.add_argument('--control-port', type=int, default=5000)
    parser.add_argument('--image-port', type=int, default=5001)
    parser.add_argument('--transfer-ip', default='192.168.1.10')
    parser.add_argument('--transfer-port', type=int, default=5002)
    parser.add_argument('--result-dir', default='E:/fpga_done_img')
    parser.add_argument('--image', default=r'C:/Users/13995/Desktop/fpga校赛/camus_processed/images/training/patient0001/patient0001_4CH_ED.png')
    parser.add_argument('--simulate', action='store_true')
    parser.add_argument('--simulate-image', action='store_true')
    parser.add_argument('--threshold', type=int, default=128)
    parser.add_argument('--pl-mode', type=int, default=1, choices=[1, 2])
    parser.add_argument('--upload-on-start', action='store_true')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()
    global _FRAME_CLIENT
    _FRAME_CLIENT = FrameTransferClient(args.transfer_ip, args.transfer_port, args.result_dir)

    web_common.HTML_PAGE = customize_page(web_common.HTML_PAGE)
    state = web_common.WebState(args.image, args.simulate)
    simulator = web_common.WebSimulator(state, args.simulate_image)
    image_sender = TcpImageSender(args.board_ip, args.image_port)
    control_worker = None if args.simulate else TcpControlWorker(state, args.board_ip, args.control_port)
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
