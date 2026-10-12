#!/usr/bin/env python3
from __future__ import annotations
import argparse
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
  const picker = document.getElementById('imageFile');
  const choose = document.getElementById('chooseImage');
  const caption = button.textContent;
  dshTransferBusy = true;
  button.disabled = picker.disabled = choose.disabled = true;
  button.textContent = '发送中，等待一帧完成…';
  try {
    const response = await fetch('/api/serial/transfer?index=0&name=' + encodeURIComponent(file.name),
      {method: 'POST', headers: {'Content-Type': 'application/octet-stream'},
       body: await file.arrayBuffer()});
    const result = await response.json();
    alert((response.ok && result.ok ? '一帧发送完成，VDMA 已停机\n\n' : '发送失败\n\n') + result.log);
  } catch (e) {
    alert('发送失败: ' + e);
  } finally {
    dshTransferBusy = false;
    button.disabled = picker.disabled = choose.disabled = false;
    button.textContent = caption;
  }
}
async function dshReadback() {
  try {
    const j = await (await fetch('/api/serial/readback')).json();
    if (!j.ok) { alert('readback FAIL\n' + j.log); return; }
    document.getElementById('dshRbMode').textContent = j.mode;
    document.getElementById('dshRbThr').textContent = j.threshold;
    const names = ['基础处理', '显示轮廓', '显示二值掩膜处理'];
    document.getElementById('dshRbVid').textContent = names[j.video_mode] || ('未知(' + j.video_mode + ')');
    document.getElementById('dshRbLes').textContent = j.lesion_mm2 + ' mm² (' + j.lesion_pixels + ' px)';
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
    poll();
  } catch (e) { alert('图像加载失败: ' + e.message); }
});
document.getElementById('upload').addEventListener('click', () => fetch('/api/upload').then(poll));
document.getElementById('fpgaOutputMode').addEventListener('change', async e => {
  try {
    const j = await (await fetch('/api/serial/video_mode?mode=' + e.target.value)).json();
    if (!j.ok) { alert('video mode FAIL\n' + j.log); return; }
    dshReadback();
  } catch (e) { alert('video mode err: ' + e); }
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
_SERIAL_LOCK = threading.Lock()
_TRANSFER_LOCK = threading.Lock()


def _serial_lock():
    return _SERIAL_LOCK
# CAMUS 数据集 letterbox 之后每个像素代表的面积 (source: camus_pipeline/convert_camus.py:64)
PIXEL_AREA_MM2 = 0.436280886141


def _board_talk(payload, wait=1.5):
    """往板子串口发字节, 返回板子打印的内容"""
    import serial
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


def _readback_regs():
    """'R' 只读回读 0x04/0x08/0x10"""
    try:
        txt = _board_talk(b"R", wait=2.0)
    except Exception as exc:
        return {"ok": False, "log": "%s: %s" % (type(exc).__name__, exc)}
    import re as _re
    m = _re.search(r"CMD_REG\(0x04\)\s*=\s*(\d+).*?DATA_REG\(0x08\)\s*=\s*(\d+).*?VIDEO_MODE\(0x10\)\s*=\s*(\d+).*?LESION\(0x14\)\s*=\s*(\d+)", txt, _re.S)
    if not m:
        return {"ok": False, "log": "cannot parse readback:" + txt}
    les = int(m.group(4))
    return {"ok": True, "mode": int(m.group(1)), "threshold": int(m.group(2)),
            "video_mode": int(m.group(3)), "lesion_pixels": les,
            "lesion_mm2": "%.3f" % (les * PIXEL_AREA_MM2), "log": txt}


def _set_video_mode(mode):
    try:
        m = int(mode)
    except (TypeError, ValueError):
        return {"ok": False, "log": "bad mode"}
    if m not in (0, 1, 2):
        return {"ok": False, "log": "mode must be 0, 1 or 2"}
    try:
        txt = _board_talk(b"V" + bytes([m]))
    except Exception as exc:
        return {"ok": False, "log": "%s: %s" % (type(exc).__name__, exc)}
    import re as _re
    match = _re.search(
        r"^\[PL rdbk\] VIDEO_MODE\(0x10\)\s*=\s*(\d+)\s*$",
        txt, _re.M)
    if not match:
        return {"ok": False, "log": "video mode write was not confirmed:\n" + txt}
    actual = int(match.group(1))
    if actual != m:
        return {"ok": False, "log": "video mode readback mismatch: "
                "requested %d, got %d\n%s" % (m, actual, txt)}
    return {"ok": True, "mode": m, "video_mode": actual, "log": txt}


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


def _do_transfer(bin_bytes, index=0, emmc_addr=EMMC_FIXED_ADDR, filename="image.bin"):
    try:
        _validate_bin_frame(bin_bytes, filename)
        if int(index) != 0:
            raise ValueError("GUI 单图传输的目录索引必须为 0")
    except Exception as exc:
        return {"ok": False, "log": str(exc)}
    if not _TRANSFER_LOCK.acquire(blocking=False):
        return {"ok": False, "log": "已有一帧正在传输，请等待完成"}

    log = []
    try:
        # One lock covers E -> A -> D, including the upload subprocess's UART.
        # Other UART commands cannot interrupt this transaction.
        with _serial_lock():
            clr = _board_talk_locked(b"E", wait=300.0)
            log.append("--- 1) E clear ---\n" + clr)
            if not any(line.strip() in ("RESULT: eMMC CLEARED",
                                        "RESULT: eMMC 已经是空的")
                       for line in clr.splitlines()):
                return {"ok": False, "log": "\n".join(log) + "\nE clear failed"}

            okc, up = _load_to_emmc_locked(bin_bytes, emmc_addr)
            log.append("--- 2) A upload ---\n" + up)
            if not (okc and "SUCCESSFUL" in up and
                    "===== END =====" in up and
                    "RESULT: VERIFY OK" in up.splitlines()):
                return {"ok": False, "log": "\n".join(log) + "\nA upload failed"}

            done = _board_talk_locked(b"D\x00\x00\x00\x00", wait=None)
            log.append("--- 3) D single frame ---\n" + done)
            if FRAME_DONE_LINE not in (line.strip() for line in done.splitlines()):
                return {"ok": False, "log": "\n".join(log) +
                        "\nD did not confirm complete single-frame transfer"}
        return {"ok": True, "frames": 1, "bytes": FRAME_BYTES, "log": "\n".join(log)}
    except Exception as exc:
        return {"ok": False, "log": "\n".join(log) +
                "\n%s: %s" % (type(exc).__name__, exc)}
    finally:
        _TRANSFER_LOCK.release()


def customize_page(page):
    page = page.replace(
        '<button id="request">请求FPGA状态</button>',
        '<button id="request">请求FPGA状态</button>'
        '<button id="chooseImage">选择 BIN 图像</button>'
        '<input id="imageFile" type="file" accept=".bin" hidden>'
        '<div>256×256，8-bit 灰度，65,536 字节</div>'
        '<div id="imageName"></div><button id="upload">上传当前图像</button>')
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
        '<div id="metrics">',
        '<div id="dshReadback">'
        '<div class="metric"><span>FPGA回读阈值模式</span><b id="dshRbMode">0</b></div>'
        '<div class="metric"><span>FPGA回读阈值</span><b id="dshRbThr">0</b></div>'
        '<div class="metric"><span>FPGA回读输出显示模式</span><b id="dshRbVid">基础处理</b></div>'
        '<div class="metric"><span>FPGA回读病灶面积</span><b id="dshRbLes">0.000 mm²</b></div>'
        '</div><div id="metrics">')
    return page.replace('</body>', TAIL_SCRIPT + '</body>')


class NetworkHandler(web_common.Handler):

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path not in ('/api/serial/transfer', '/api/image'):
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
                self.state.replace_image(data, filename)
                self.send_json({'ok': True, 'name': self.state.image_name})
            else:
                index = query.get('index', ['0'])[0]
                self.send_json(_do_transfer(data, index, filename=filename))
        except Exception as exc:
            message = '%s: %s' % (type(exc).__name__, exc)
            self.send_json({'ok': False, 'log': message, 'error': message}, status=400)

    image_sender = None
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
            if 'simulate' in query:
                with self.state.lock:
                    self.state.simulate = not self.state.simulate
            if 'mode' in query:
                # mode is the local display mode; do not write PL MODE_REG.
                pass
            self.send_json({'ok': True})
            return
        if parsed.path == '/api/upload':
            try:
                if self.image_sender is None:
                    raise RuntimeError('image sender is not configured')
                with self.state.lock:
                    image = self.state.image.copy()
                result = self.image_sender.send_image(image, self.server.next_image_frame())
                if self.control_worker is not None:
                    self.control_worker.write(proto.encode_set_threshold(self.server.threshold))
                    self.control_worker.write(proto.encode_set_mode(self.server.pl_mode))
                    self.control_worker.write(proto.encode_start_analyze())
                self.state.log(f"图像上传完成并启动分析: {result['bytes']} bytes, {result['elapsed_ms']:.2f} ms")
                self.send_json({'ok': True, 'result': result})
            except Exception as exc:
                self.state.log(f'图像上传失败: {exc}')
                self.send_json({'ok': False, 'error': str(exc)})
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
    parser.add_argument('--image', default=r'C:/Users/13995/Desktop/fpga校赛/camus_processed/images/training/patient0001/patient0001_4CH_ED.png')
    parser.add_argument('--simulate', action='store_true')
    parser.add_argument('--simulate-image', action='store_true')
    parser.add_argument('--threshold', type=int, default=128)
    parser.add_argument('--pl-mode', type=int, default=1, choices=[1, 2])
    parser.add_argument('--upload-on-start', action='store_true')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()

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
    NetworkHandler.image_sender = image_sender
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
    server.frame_counter = 0
    server.threshold = args.threshold
    server.pl_mode = args.pl_mode
    def next_image_frame():
        server.frame_counter = (server.frame_counter + 1) & 0xFFFF
        return server.frame_counter
    server.next_image_frame = next_image_frame
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
