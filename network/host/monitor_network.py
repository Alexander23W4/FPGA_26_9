#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import socket
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
from frame_transfer import FrameTransferClient


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
function dshValidateBin(file) {
  if (!file || !file.name.toLowerCase().endsWith('.bin') || file.size !== 65536)
    throw new Error('请选择 256x256x8-bit 的 BIN 文件，大小必须恰好为 65536 字节');
}
function dshThrUpdate() {
  const sw = document.getElementById('thresholdMode');
  const manual = sw.getAttribute('aria-checked') === 'true';
  const v = document.getElementById('threshold').value;
  fetch('/api/serial/threshold?mode=' + (manual ? 1 : 0) + '&value=' + v)
    .then(r => r.json()).then(j => alert((j.ok ? 'threshold OK\n' : 'threshold FAIL\n') + j.log))
    .catch(e => alert('threshold err: ' + e));
}
async function dshTransfer() {
  if (dshTransferBusy) return;
  const file = document.getElementById('imageFile').files[0];
  try { dshValidateBin(file); } catch (e) { alert(e.message); return; }
  const button = document.getElementById('transfer');
  const caption = button.textContent;
  const mode = document.getElementById('fpgaOutputMode').value;
  const controls = ['transfer', 'imageFile', 'chooseImage', 'fpgaOutputMode', 'thresholdMode',
    'threshold', 'thresholdUpdate', 'maskOpacity', 'maskOpacityUpdate', 'request'];
  const disabled = controls.map(id => document.getElementById(id).disabled);
  dshTransferBusy = true;
  controls.forEach(id => { document.getElementById(id).disabled = true; });
  if (typeof updateModeMenu === 'function') updateModeMenu();
  button.textContent = mode === '5' ? '全显示处理中：0/5…' : '网口传输中，等待回传保存…';
  try {
    const response = await fetch('/api/network/transfer?index=0&name=' + encodeURIComponent(file.name) + '&mode=' + mode,
      {method: 'POST', headers: {'Content-Type': 'application/octet-stream'},
       body: await file.arrayBuffer()});
    const result = await response.json();
    if (typeof renderProcessedResults === 'function' && result.results)
      renderProcessedResults(Object.fromEntries(result.results.map(item => [String(item.mode), item])));
    alert((response.ok && result.ok ? 'FPGA 处理完成，结果已保存到 PC\n\n' : '发送失败\n\n') + result.log);
  } catch (e) {
    alert('发送失败: ' + e);
  } finally {
    dshTransferBusy = false;
    controls.forEach((id, i) => { document.getElementById(id).disabled = disabled[i]; });
    if (typeof updateModeMenu === 'function') updateModeMenu();
    if (typeof updateThresholdControls === 'function') updateThresholdControls();
    button.textContent = caption;
  }
}
async function dshReadback() {
  try {
    const j = await (await fetch('/api/serial/readback')).json();
    if (!j.ok) { alert('readback FAIL\n' + j.log); return; }
    document.getElementById('dshRbMode').textContent = j.mode === 1 ? '手动' : '自动';
    document.getElementById('dshRbThr').textContent = j.threshold;
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
    if (!dshTransferBusy && document.getElementById('fpgaOutputMode').value !== '5')
      document.getElementById('fpgaOutputMode').value = j.video_mode;
    document.getElementById('maskOpacity').value = j.mask_transparency;
    document.getElementById('maskOpacityValue').textContent = j.mask_transparency;
    updateOverlayControls();
    updatePreviewLayout();
  } catch (e) { alert('readback err: ' + e); }
}
document.getElementById('request').addEventListener('click', dshReadback);
document.getElementById('chooseImage').addEventListener('click', () => document.getElementById('imageFile').click());
document.getElementById('imageFile').addEventListener('change', async e => {
  const file = e.target.files[0];
  if (!file) return;
  try {
    dshValidateBin(file);
    const response = await fetch('/api/image?name=' + encodeURIComponent(file.name),
      {method: 'POST', headers: {'Content-Type': 'application/octet-stream'}, body: file});
    const j = await response.json();
    if (!response.ok || !j.ok) throw new Error(j.error || j.log);
    document.getElementById('imageName').textContent = '当前图像: ' + j.name;
    renderProcessedResults({});
    poll();
  } catch (e) { alert('图像加载失败: ' + e.message); }
});
let lastConfirmedVideoMode = 0;
document.getElementById('fpgaOutputMode').addEventListener('change', async e => {
    const outputModeNote = document.getElementById('outputModeNote');
    if (e.target.value === '5') {
        outputModeNote.textContent = '发送后依次处理模式 0–4，显示原图及五张 FPGA 回传图';
        return;
    }
    outputModeNote.textContent = '设置开发板 HDMI 的输出内容';
  try {
    const j = await (await fetch('/api/serial/video_mode?mode=' + e.target.value)).json();
    if (!j.ok) {
      e.target.value = lastConfirmedVideoMode;
      updateOverlayControls();
    updatePreviewLayout();
      alert('video mode FAIL\n' + j.log); return;
    }
    lastConfirmedVideoMode = j.video_mode;
    dshReadback();
  } catch (error) {
    e.target.value = lastConfirmedVideoMode;
    updateOverlayControls();
    updatePreviewLayout();
    alert('video mode err: ' + error);
  }
});
document.getElementById('maskOpacityUpdate').addEventListener('click', async e => {
  const button = e.currentTarget;
  button.disabled = true;
  try {
    const value = document.getElementById('maskOpacity').value;
    const result = await (await fetch('/api/serial/mask_transparency?value=' + value)).json();
    if (!result.ok) throw new Error(result.log);
    button.textContent = '已更新';
    await dshReadback();
  } catch (error) { alert('掩膜透明度更新失败: ' + error.message); }
  finally { button.disabled = false; }
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
        while deadline is None or time.monotonic() < deadline:
            c = s.read(4096)
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
        return {"ok": True, "log": _board_talk(b"T" + bytes([mode, v]))}
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


def _do_transfer(bin_bytes, index=0, filename="image.bin", mode=0, state=None):
    """Serialize mode write -> upload -> durable result -> PL ACK -> GUI, per mode."""
    global _DISPLAY_PENDING
    try:
        _validate_bin_frame(bin_bytes, filename)
        if int(index) != 0:
            raise ValueError("单帧网口传输的索引必须为 0")
        mode = int(mode)
        if mode not in range(6):
            raise ValueError("处理模式必须为 0..5（5 为全显示）")
    except Exception as exc:
        return {"ok": False, "log": str(exc)}
    if not _TRANSFER_LOCK.acquire(blocking=False):
        return {"ok": False, "log": "已有一帧正在传输，请等待完成"}
    results = []
    modes = list(range(5)) if mode == 5 else [mode]
    context = None
    try:
        key = (hashlib.sha256(bin_bytes).digest(), filename, mode)
        if _DISPLAY_PENDING is not None:
            if _DISPLAY_PENDING['key'] != key:
                raise RuntimeError("上一任务的回传尚未确认，请使用相同原图和显示模式重试")
            context = _DISPLAY_PENDING
        else:
            context = {'key': key, 'results': []}
        results = context['results']
        if state is not None:
            state.replace_image(bin_bytes, filename)
            with state.lock:
                state.processed_results = {str(item['mode']): item for item in results}
                state.transfer_status = {'busy': True, 'completed': len(results), 'total': len(modes)}
        # RLock allows the checked UART write to use the same serial bridge.
        # Keep settings fixed for the entire batch, including every return ACK.
        with _serial_lock():
            for current_mode in modes[len(results):]:
                if state is not None:
                    with state.lock:
                        state.transfer_status.update(mode=current_mode)
                # RESUME owns the old mode until its saved result is acknowledged.
                if _FRAME_CLIENT.pending is None:
                    written = _set_video_mode(current_mode)
                    if not written['ok']:
                        raise RuntimeError('显示模式更新失败: ' + written['log'])
                result = _FRAME_CLIENT.transfer(bin_bytes, filename, expected_mode=current_mode)
                results.append(result)
                if state is not None:
                    with state.lock:
                        state.processed_results[str(current_mode)] = result
                        state.transfer_status.update(completed=len(results))
                    state.log('模式 %d 回传已保存并确认: %s' % (current_mode, result['files']['bin']))
        _DISPLAY_PENDING = None
        return {'ok': True, 'frames': len(results), 'bytes': FRAME_BYTES * len(results),
                'output_bytes': sum(item['output_bytes'] for item in results),
                'results': results, 'files': results[-1]['files'],
                'log': '\n'.join(item['log'] for item in results)}
    except Exception as exc:
        if context is not None:
            _DISPLAY_PENDING = context if _FRAME_CLIENT.pending is not None else None
        message = "%s: %s" % (type(exc).__name__, exc)
        if state is not None:
            state.log('处理失败: ' + message)
        return {"ok": False, "results": results, "log": message}
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
        '<button id="transfer">传输给FPGA</button>',
        '<button id="transfer" onclick="dshTransfer()">传输给FPGA</button>')
    page = page.replace(
        '<div id="metrics"',
        '<div id="dshReadback" data-system-mode="processing">'
        '<div class="metric"><span>掩膜面积</span><b id="dshRbLes">—</b></div>'
        '<div class="metric"><span>分割阈值</span><b id="dshRbThr">—</b></div>'
        '<div class="metric"><span>阈值模式</span><b id="dshRbMode">—</b></div>'
        '<div class="metric"><span>输出显示</span><b id="dshRbVid">—</b></div>'
        '<div class="metric"><span>掩膜透明度</span><b id="dshRbAlpha">—</b></div>'
        '</div><div id="metrics"')
    return page.replace('</body>', TAIL_SCRIPT + '</body>')


class NetworkHandler(web_common.Handler):

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path not in ('/api/network/transfer', '/api/serial/transfer', '/api/image'):
            super().do_POST()
            return
        try:
            query = parse_qs(parsed.query)
            filename = query.get('name', [''])[0]
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
                    self.state.replace_image(data, filename)
                finally:
                    _TRANSFER_LOCK.release()
                self.send_json({'ok': True, 'name': self.state.image_name})
            else:
                index = query.get('index', ['0'])[0]
                mode = query.get('mode', ['0'])[0]
                self.send_json(_do_transfer(data, index, filename=filename, mode=mode, state=self.state))
        except Exception as exc:
            message = '%s: %s' % (type(exc).__name__, exc)
            self.send_json({'ok': False, 'log': message, 'error': message}, status=400)

    control_worker = None

    def do_GET(self):
        parsed = urlparse(self.path)
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
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
