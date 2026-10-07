#!/usr/bin/env python3
from __future__ import annotations
import argparse
import socket
import sys
import threading
import time
import webbrowser
from pathlib import Path
from urllib.parse import urlparse
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
        image = load_gray(path)
        packets = proto.encode_image_packets(image.tobytes(), 256, 256, frame_id, self.chunk_size)
        start = time.perf_counter()
        with socket.create_connection((self.host, self.port), timeout=3.0) as sock:
            for packet in packets:
                sock.sendall(packet)
        elapsed = time.perf_counter() - start
        return {'frame_id': frame_id, 'packets': len(packets), 'bytes': image.size,
                'elapsed_ms': elapsed * 1000.0,
                'Mbps': image.size * 8.0 / max(elapsed, 1e-9) / 1e6}


def customize_page(page):
    page = page.replace('<button id="request">请求FPGA状态</button>',
                        '<button id="request">请求FPGA状态</button><button id="upload">上传当前图像</button>')
    page = page.replace("document.getElementById('request').addEventListener('click',()=>fetch('/api/command?request=1'));",
                        "document.getElementById('request').addEventListener('click',()=>fetch('/api/command?request=1'));document.getElementById('upload').addEventListener('click',()=>fetch('/api/upload').then(poll));")
    page = page.replace('serial:j.serial_connected?', 'network:j.serial_connected?')
    return page


class NetworkHandler(web_common.Handler):
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
                result = self.image_sender.send_file(self.server.image_path, self.server.next_image_frame())
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
