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
        self.processed_results: dict[str, dict] = {}
        self.transfer_status: dict = {}
        self.source_revision = 0
        self.results_revision = 0
        self.source_kind = "image"
        self.stream_folder = ""

    def replace_image(self, data: bytes, filename: str, *,
                      preserve_results: bool = False, display_name: str | None = None) -> None:
        image = decode_gray_image(data, filename)
        source_kind = "stream" if preserve_results else "image"
        stream_folder = str(display_name or "") if preserve_results else ""
        with self.lock:
            same_stream = (source_kind == "stream"
                           and self.source_kind == "stream"
                           and self.stream_folder == stream_folder)
            self.image = image
            self.image_name = str(display_name) if display_name is not None else Path(filename).name
            self.mask = None
            self.source_kind = source_kind
            self.stream_folder = stream_folder
            self.source_revision += 1
            if not (preserve_results and same_stream):
                self.processed_results = {}
                self.results_revision += 1
        self.log(f"已选择图像: {self.image_name}")

    def publish_result(self, result: dict, *, stream: bool = False) -> dict:
        """Publish a freshly received result, never an existing file lookup."""
        published = dict(result)
        if "files" in published:
            published["files"] = dict(published["files"])
        mode = str(int(published["mode"]))
        with self.lock:
            if stream:
                self.processed_results = {mode: published}
            else:
                self.processed_results[mode] = published
            self.results_revision += 1
        return dict(published)

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

    def original_snapshot(self) -> dict[str, object]:
        with self.lock:
            original = self.image.copy()
            image_name = self.image_name
            source_revision = getattr(self, "source_revision", 0)
            results_revision = getattr(self, "results_revision", 0)
            source_kind = getattr(self, "source_kind", "image")
            stream_folder = getattr(self, "stream_folder", "")
        output = io.BytesIO()
        Image.fromarray(original).save(output, format="PNG")
        return {"image": base64.b64encode(output.getvalue()).decode("ascii"),
                "image_name": image_name, "source_revision": source_revision,
                "results_revision": results_revision, "source_kind": source_kind,
                "stream_folder": stream_folder}

    def snapshot(self, mode: int, center: int, width: int, alpha: int, *, include_images=True) -> dict[str, object]:
        with self.lock:
            status = dict(self.status)
            logs = list(self.logs)
            simulate = self.simulate
            connected = self.serial_connected
            image_name = self.image_name
            processed_results = dict(self.processed_results) if include_images else None
            transfer_status = dict(self.transfer_status)
            source_revision = self.source_revision
            results_revision = self.results_revision
            source_kind = self.source_kind
            stream_folder = self.stream_folder
            original = self.image.copy() if include_images and not simulate else None
        status["mode_name"] = MODE_NAMES[status.get("mode", mode)] if int(status.get("mode", mode)) < len(MODE_NAMES) else str(status.get("mode", mode))
        if not include_images:
            return {"status": status, "logs": logs, "simulate": simulate,
                    "serial_connected": connected, "transfer_status": transfer_status,
                    "image_name": image_name, "source_revision": source_revision,
                    "results_revision": results_revision, "source_kind": source_kind,
                    "stream_folder": stream_folder}
        if original is not None:
            output = io.BytesIO()
            Image.fromarray(original).save(output, format="PNG")
            preview = base64.b64encode(output.getvalue()).decode("ascii")
        else:
            preview = self.render_png(mode, center, width, alpha)
        return {"image": preview, "status": status,
                "logs": logs, "simulate": simulate, "serial_connected": connected,
                "image_name": image_name, "processed_results": processed_results,
                "transfer_status": transfer_status, "source_revision": source_revision,
                "results_revision": results_revision, "source_kind": source_kind,
                "stream_folder": stream_folder}


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


GUI_ASSET_DIR = Path(__file__).resolve().parent / "assets"
GUI_STATIC_FILES = {
    "/assets/heartcare.css": ("heartcare.css", "text/css; charset=utf-8"),
    "/assets/heartcare.js": ("heartcare.js", "text/javascript; charset=utf-8"),
    "/assets/stream_worker.js": ("stream_worker.js", "text/javascript; charset=utf-8"),
    "/assets/InterVariable.woff2": ("InterVariable.woff2", "font/woff2"),
    "/assets/ManropeVariable.ttf": ("ManropeVariable.ttf", "font/ttf"),
    "/assets/heart-pulse.svg": ("heart-pulse.svg", "image/svg+xml"),
    "/assets/workspace-texture.svg": ("workspace-texture.svg", "image/svg+xml"),
}
HTML_PAGE = (GUI_ASSET_DIR / "heartcare.html").read_text(encoding="utf-8")


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
        asset = GUI_STATIC_FILES.get(parsed.path)
        if asset is not None:
            try:
                body = (GUI_ASSET_DIR / asset[0]).read_bytes()
            except OSError:
                self.send_json({"error": "UI asset unavailable"}, status=404)
                return
            self.send_response(200)
            self.send_header("Content-Type", asset[1])
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/":
            body = HTML_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            # ★ 不许浏览器缓存页面: 否则改了前端, 用户按 F5 拿到的还是旧页面
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/image":
            self.send_json({"error": "POST an image file"}, status=405)
            return
        if parsed.path == "/api/original":
            self.send_json(self.state.original_snapshot())
            return
        if parsed.path == "/api/state":
            mode = int(query.get("mode", ["3"])[0])
            center = int(query.get("center", ["128"])[0])
            width = int(query.get("width", ["255"])[0])
            alpha = int(query.get("alpha", ["45"])[0])
            self.send_json(self.state.snapshot(mode, center, width, alpha))
            return
        if parsed.path == "/api/system_mode":
            mode = query.get("mode", [""])[0]
            if mode not in ("simulation", "processing"):
                self.send_json({"ok": False, "error": "unsupported system mode"}, status=400)
                return
            with self.state.lock:
                self.state.simulate = mode == "simulation"
            self.send_json({"ok": True, "simulate": mode == "simulation"})
            return
        if parsed.path == "/api/command":
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
