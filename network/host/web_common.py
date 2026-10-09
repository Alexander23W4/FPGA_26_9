#!/usr/bin/env python3
"""Browser-based FPGA medical image monitor using only Python standard HTTP."""
from __future__ import annotations
import argparse
import base64
import io
import json
import math
import queue
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'vendor'))
from urllib.parse import parse_qs, urlparse

import numpy as np
from PIL import Image

import protocol as proto

try:
    import serial
except Exception:
    serial = None

MODE_NAMES = ["原图", "增强", "掩膜", "叠加"]
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".bin"}
MAX_IMAGE_UPLOAD_BYTES = 16 * 1024 * 1024


def decode_gray_image(data: bytes, filename: str) -> np.ndarray:
    suffix = Path(filename).suffix.lower()
    if suffix not in IMAGE_SUFFIXES:
        raise ValueError(f"unsupported image format: {suffix or '(no extension)'}")
    if suffix == ".bin":
        data_array = np.frombuffer(data, dtype=np.uint8)
        if data_array.size != 256 * 256:
            raise ValueError(f"expected 65536 bytes, got {data_array.size}")
        return data_array.reshape(256, 256).copy()
    with Image.open(io.BytesIO(data)) as image:
        return np.asarray(image.convert("L").resize((256, 256), Image.Resampling.BILINEAR), dtype=np.uint8)


def load_gray(path: str | Path) -> np.ndarray:
    path = Path(path)
    return decode_gray_image(path.read_bytes(), path.name)


def window_level(image: np.ndarray, center: int, width: int) -> np.ndarray:
    center = int(max(0, min(255, center)))
    width = max(1, min(255, int(width)))
    low = center - width / 2.0
    high = center + width / 2.0
    lut = np.clip((np.arange(256, dtype=np.float32) - low) * (255.0 / (high - low)), 0, 255).astype(np.uint8)
    return lut[image]


def render_rgb(image: np.ndarray, mask: np.ndarray | None, mode: int, center: int, width: int, alpha: int) -> np.ndarray:
    base = window_level(image, center, width)
    if mode == 0:
        return np.repeat(base[:, :, None], 3, axis=2)
    if mode == 1:
        enhanced = (255.0 * ((base.astype(np.float32) / 255.0) ** 0.75)).clip(0, 255).astype(np.uint8)
        return np.repeat(enhanced[:, :, None], 3, axis=2)
    if mode == 2:
        if mask is None:
            m = np.zeros_like(base)
        else:
            m = (mask.astype(np.uint8) * 255).reshape(256, 256)
        return np.repeat(m[:, :, None], 3, axis=2)
    rgb = np.repeat(base[:, :, None], 3, axis=2).astype(np.float32)
    if mask is not None:
        m = mask.reshape(256, 256).astype(bool)
        a = max(0.0, min(1.0, alpha / 100.0))
        color = np.array([235.0, 55.0, 55.0], dtype=np.float32)
        rgb[m] = rgb[m] * (1.0 - a) + color * a
        edge = m & ~(np.roll(m, 1, 0) & np.roll(m, -1, 0) & np.roll(m, 1, 1) & np.roll(m, -1, 1))
        rgb[edge] = np.array([0.0, 255.0, 240.0], dtype=np.float32)
    return np.clip(rgb, 0, 255).astype(np.uint8)


class WebState:
    def __init__(self, image_path: str, simulate: bool):
        self.lock = threading.Lock()
        self.image = load_gray(image_path)
        self.image_name = Path(image_path).name
        self.mask: np.ndarray | None = None
        self.status: dict[str, int | float] = {}
        self.mask_assembler = proto.MaskAssembler()
        self.image_assembler = proto.ImageAssembler()
        self.logs: list[str] = []
        self.simulate = simulate
        self.serial_connected = False

    def replace_image(self, data: bytes, filename: str) -> None:
        image = decode_gray_image(data, filename)
        with self.lock:
            self.image = image
            self.image_name = Path(filename).name
            self.mask = None
        self.log(f"已选择图像: {self.image_name}")

    def log(self, message: str) -> None:
        with self.lock:
            self.logs.append(f"[{time.strftime('%H:%M:%S')}] {message}")
            self.logs = self.logs[-200:]

    def handle_packet(self, packet: proto.Packet) -> None:
        with self.lock:
            if packet.command == proto.CMD_STATUS:
                self.status = proto.decode_status(packet.payload)
            elif packet.command == proto.CMD_MASK_RLE:
                result = self.mask_assembler.feed(packet.payload)
                if result is not None:
                    _frame_id, width, height, decoded = result
                    self.mask = np.frombuffer(decoded, dtype=np.uint8).reshape(height, width)
            elif packet.command == proto.CMD_IMAGE_RAW:
                result = self.image_assembler.feed(packet.payload)
                if result is not None:
                    _frame_id, width, height, decoded = result
                    frame = Image.fromarray(np.frombuffer(decoded, dtype=np.uint8).reshape(height, width), mode="L")
                    self.image = np.asarray(frame.resize((256, 256), Image.Resampling.BILINEAR), dtype=np.uint8)

    def render_png(self, mode: int, center: int, width: int, alpha: int) -> str:
        with self.lock:
            rgb = render_rgb(self.image.copy(), None if self.mask is None else self.mask.copy(), mode, center, width, alpha)
        output = io.BytesIO()
        Image.fromarray(rgb, mode="RGB").save(output, format="PNG", optimize=True)
        return base64.b64encode(output.getvalue()).decode("ascii")

    def snapshot(self, mode: int, center: int, width: int, alpha: int) -> dict[str, object]:
        with self.lock:
            status = dict(self.status)
            logs = list(self.logs)
            simulate = self.simulate
            connected = self.serial_connected
            image_name = self.image_name
        status["mode_name"] = MODE_NAMES[status.get("mode", mode)] if int(status.get("mode", mode)) < len(MODE_NAMES) else str(status.get("mode", mode))
        return {"image": self.render_png(mode, center, width, alpha), "status": status,
                "logs": logs, "simulate": simulate, "serial_connected": connected,
                "image_name": image_name}


class WebSimulator:
    def __init__(self, state: WebState, emit_image: bool = False):
        self.state = state
        self.emit_image = emit_image
        self.frame_id = 0
        self.phase = 0.0
        self.mode = 3
        self.threshold = 128
        self.decoder = proto.FrameDecoder()
        self.image_sent = False

    def emit_bytes(self, data: bytes) -> None:
        for packet in self.decoder.feed(data):
            self.state.handle_packet(packet)

    def tick(self) -> None:
        with self.state.lock:
            if not self.state.simulate:
                return
        self.frame_id = (self.frame_id + 1) & 0xFFFF
        self.phase += 0.06
        yy, xx = np.ogrid[:256, :256]
        cx = 128 + int(20 * math.sin(self.phase))
        cy = 128 + int(12 * math.cos(self.phase * 0.7))
        rx = 54 + int(8 * math.sin(self.phase * 1.3))
        ry = 72 + int(6 * math.cos(self.phase))
        mask = (((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2 <= 1.0)
        mask |= (((xx - cx) / (rx * 0.55)) ** 2 + ((yy - cy - 20) / (ry * 0.55)) ** 2 <= 1.0)
        mask_u8 = mask.astype(np.uint8)
        area = int(mask_u8.sum())
        spacing = 0.6605156214209273
        inference_us = 18000 + int(4000 * abs(math.sin(self.phase)))
        for packet in proto.encode_mask_packets(mask_u8, 256, 256, self.frame_id, 1000):
            self.emit_bytes(packet)
        self.emit_bytes(proto.encode_status(self.mode, self.threshold, area, int(area * spacing * spacing * 100), self.frame_id, inference_us))
        if self.emit_image and not self.image_sent:
            rng = np.random.default_rng(7)
            noise = rng.normal(110, 25, (128, 128)).clip(0, 255).astype(np.uint8)
            for packet in proto.encode_image_packets(noise.tobytes(), 128, 128, self.frame_id, 1024):
                self.emit_bytes(packet)
            self.image_sent = True


class SerialWorker(threading.Thread):
    def __init__(self, state: WebState, port: str, baud: int):
        super().__init__(daemon=True)
        self.state = state
        self.port = port
        self.baud = baud
        self.stop_event = threading.Event()
        self.decoder = proto.FrameDecoder()
        self.ser = None
        self.lock = threading.Lock()

    def run(self) -> None:
        if serial is None:
            self.state.log("pyserial未安装，串口模式不可用")
            return
        try:
            self.ser = serial.Serial(self.port, self.baud, timeout=0.05)
            self.state.serial_connected = True
            self.state.log(f"串口已连接 {self.port} @ {self.baud}")
        except Exception as exc:
            self.state.log(f"串口打开失败: {exc}")
            return
        while not self.stop_event.is_set():
            try:
                data = self.ser.read(4096)
                if data:
                    for packet in self.decoder.feed(data):
                        self.state.handle_packet(packet)
            except Exception as exc:
                self.state.log(f"串口读取失败: {exc}")
                break
        self.state.serial_connected = False
        try:
            self.ser.close()
        except Exception:
            pass
        self.state.log("串口已断开")

    def write(self, packet: bytes) -> bool:
        if self.ser is None or not self.ser.is_open:
            return False
        try:
            with self.lock:
                self.ser.write(packet)
            return True
        except Exception as exc:
            self.state.log(f"串口写入失败: {exc}")
            return False


HTML_PAGE = """<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>FPGA医学影像监控</title>
<style>
body{margin:0;background:#0f1720;color:#e5edf5;font-family:Segoe UI,Microsoft YaHei,sans-serif}
.wrap{display:flex;min-height:100vh}.panel{width:330px;padding:16px;background:#16222d;box-sizing:border-box}
.view{flex:1;display:flex;align-items:center;justify-content:center;padding:18px}.view img{width:min(78vh,90%);image-rendering:pixelated;border:1px solid #385064;background:#000}
h1{font-size:20px;margin:0 0 14px}label{display:block;margin:12px 0 4px}input[type=range]{width:100%}
select,button{width:100%;padding:7px;background:#203342;color:#fff;border:1px solid #426078;border-radius:5px}
button{cursor:pointer;margin-top:6px}.metric{display:flex;justify-content:space-between;border-bottom:1px solid #263b4b;padding:5px 0}
.threshold-mode{display:flex;align-items:center;justify-content:space-between;margin:12px 0 4px}
.threshold-mode label{margin:0}
.switch{position:relative;width:48px;height:26px;padding:0;margin:0;border:0;border-radius:999px;background:#164674;transition:background .2s;flex:none}
.switch::after{content:"";position:absolute;width:20px;height:20px;left:3px;top:3px;border-radius:50%;background:#1687ff;transition:transform .2s,background .2s}
.switch[aria-checked="true"]{background:#1b5d94}
.switch[aria-checked="true"]::after{transform:translateX(22px);background:#1687ff}
.switch:disabled{cursor:not-allowed;background:#303a42;opacity:.65}
.switch:disabled::after{background:#737e86}
.threshold-value{display:flex;justify-content:space-between;align-items:center}
input:disabled{opacity:.4;cursor:not-allowed}
pre{white-space:pre-wrap;max-height:180px;overflow:auto;font-size:12px;background:#0c141b;padding:8px}
</style></head><body><div class="wrap">
<div class="panel"><h1>FPGA医学影像监控</h1>
<label>显示模式</label><select id="mode"><option value="0">原图</option><option value="1">增强</option><option value="2">掩膜</option><option value="3" selected>叠加</option></select>
<div class="threshold-mode"><label id="thresholdModeLabel" for="thresholdMode">阈值模式：自动</label><button id="thresholdMode" class="switch" type="button" role="switch" aria-checked="false" aria-label="切换自动或手动阈值模式" disabled></button></div>
<div class="threshold-value"><label for="threshold">分割阈值</label><span id="thresholdValue">128</span></div><input id="threshold" type="range" min="0" max="255" value="128" disabled>
<label>窗位 <span id="centerValue">128</span></label><input id="center" type="range" min="0" max="255" value="128">
<label>窗宽 <span id="widthValue">255</span></label><input id="width" type="range" min="1" max="255" value="255">
<label>叠加透明度 <span id="alphaValue">45</span>%</label><input id="alpha" type="range" min="0" max="100" value="45">
<button id="simulate">切换模拟模式</button><button id="request">请求FPGA状态</button><button id="transfer">传输给FPGA</button>
<div id="metrics"></div><pre id="logs"></pre></div>
<div class="view"><img id="view" alt="FPGA display"></div></div>
<script>
const ids=['threshold','center','width','alpha'];for(const id of ids){const e=document.getElementById(id);e.addEventListener('input',()=>{document.getElementById(id+'Value').textContent=e.value;});}
const thresholdMode=document.getElementById('thresholdMode');const threshold=document.getElementById('threshold');let simulateOn=false;
function updateThresholdControls(){thresholdMode.disabled=simulateOn;const manual=thresholdMode.getAttribute('aria-checked')==='true';document.getElementById('thresholdModeLabel').textContent='阈值模式：'+(manual?'手动':'自动');threshold.disabled=simulateOn||!manual;}
let lastThreshold=null;function sendThreshold(){if(simulateOn||thresholdMode.getAttribute('aria-checked')!=='true')return;const t=threshold.value;if(t!==lastThreshold){lastThreshold=t;fetch('/api/command?threshold='+t);}}
thresholdMode.addEventListener('click',()=>{thresholdMode.setAttribute('aria-checked',thresholdMode.getAttribute('aria-checked')!=='true'?'true':'false');lastThreshold=null;updateThresholdControls();sendThreshold();});
setInterval(sendThreshold,150);
document.getElementById('mode').addEventListener('change',e=>fetch('/api/command?mode='+e.target.value));
document.getElementById('simulate').addEventListener('click',()=>fetch('/api/command?simulate=toggle').then(poll));
document.getElementById('request').addEventListener('click',()=>fetch('/api/command?request=1'));
function setSimulateState(enabled){if(simulateOn!==enabled){lastThreshold=null;}simulateOn=enabled;updateThresholdControls();}
updateThresholdControls();
async function poll(){try{const q=new URLSearchParams({mode:document.getElementById('mode').value,center:document.getElementById('center').value,width:document.getElementById('width').value,alpha:document.getElementById('alpha').value});const r=await fetch('/api/state?'+q);const j=await r.json();setSimulateState(Boolean(j.simulate));document.getElementById('view').src='data:image/png;base64,'+j.image;document.getElementById('imageName').textContent='当前图像: '+j.image_name;const s=j.status||{};const rows={frame:s.frame_id,mode:s.mode_name,threshold:s.threshold,area_pixels:s.area_pixels,area_mm2:s.area_mm2,inference_ms:s.inference_us===undefined?'-':(s.inference_us/1000).toFixed(3),serial:j.serial_connected?'connected':'offline',simulate:j.simulate?'on':'off'};document.getElementById('metrics').innerHTML=Object.entries(rows).map(([k,v])=>'<div class="metric"><span>'+k+'</span><b>'+(v===undefined?'-':v)+'</b></div>').join('');document.getElementById('logs').textContent=(j.logs||[]).join('\\n');}catch(e){}}
poll();setInterval(poll,150);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    state: WebState
    serial_worker: SerialWorker | None = None
    simulator: WebSimulator | None = None

    def log_message(self, _format, *_args):
        return

    def send_json(self, data: dict[str, object], status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/":
            body = HTML_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/image":
            self.send_json({"error": "POST an image file"}, status=405)
            return
        if parsed.path == "/api/state":
            mode = int(query.get("mode", ["3"])[0])
            center = int(query.get("center", ["128"])[0])
            width = int(query.get("width", ["255"])[0])
            alpha = int(query.get("alpha", ["45"])[0])
            self.send_json(self.state.snapshot(mode, center, width, alpha))
            return
        if parsed.path == "/api/command":
            if "simulate" in query:
                with self.state.lock:
                    self.state.simulate = not self.state.simulate
            if "mode" in query:
                mode_value = int(query["mode"][0])
                if self.simulator is not None:
                    self.simulator.mode = mode_value
                if self.serial_worker is not None:
                    self.serial_worker.write(proto.encode_set_mode(mode_value))
            if "threshold" in query:
                threshold_value = int(query["threshold"][0])
                if self.simulator is not None:
                    self.simulator.threshold = threshold_value
                if self.serial_worker is not None:
                    self.serial_worker.write(proto.encode_set_threshold(threshold_value))
            if "request" in query and self.serial_worker is not None:
                self.serial_worker.write(proto.encode_request_status())
            self.send_json({"ok": True})
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/api/image":
            self.send_response(404)
            self.end_headers()
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json({"error": "invalid Content-Length"}, status=400)
            return
        if content_length <= 0:
            self.send_json({"error": "empty image upload"}, status=400)
            return
        if content_length > MAX_IMAGE_UPLOAD_BYTES:
            self.send_json({"error": "image upload exceeds 16 MiB"}, status=413)
            return
        filename = parse_qs(parsed.query).get("name", [""])[0]
        try:
            data = self.rfile.read(content_length)
            if len(data) != content_length:
                raise ValueError("incomplete image upload")
            self.state.replace_image(data, filename)
        except (OSError, ValueError) as exc:
            self.state.log(f"图像选择失败: {exc}")
            self.send_json({"error": str(exc)}, status=400)
            return
        self.send_json({"ok": True, "name": self.state.image_name})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--serial-port", default="")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--image", default=r"C:/Users/13995/Desktop/fpga校赛/camus_processed/images/training/patient0001/patient0001_4CH_ED.png")
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument("--simulate-image", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    state = WebState(args.image, args.simulate)
    simulator = WebSimulator(state, args.simulate_image)
    serial_worker = SerialWorker(state, args.serial_port, args.baud) if args.serial_port else None
    Handler.state = state
    Handler.simulator = simulator
    Handler.serial_worker = serial_worker
    if serial_worker is not None:
        serial_worker.start()
    def background():
        while True:
            if state.simulate:
                simulator.tick()
            time.sleep(0.1)
    threading.Thread(target=background, daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    state.log("监控服务已启动: " + url)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
