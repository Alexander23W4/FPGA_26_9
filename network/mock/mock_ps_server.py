#!/usr/bin/env python3
import argparse
import socket
import threading
import sys
import time
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import protocol as proto

class MockPS:
    def __init__(self, host, control_port, image_port):
        self.host = host
        self.control_port = control_port
        self.image_port = image_port
        self.stop_event = threading.Event()
        self.control_clients = []
        self.threshold = 128
        self.mode = 3
        self.frame_id = 0
        self.image = None
        self.assembler = proto.ImageAssembler()

    def send_to_controls(self, packet):
        for client in list(self.control_clients):
            try:
                client.sendall(packet)
            except OSError:
                self.control_clients.remove(client)

    def recv_client(self, client):
        decoder = proto.FrameDecoder()
        while not self.stop_event.is_set():
            try:
                data = client.recv(4096)
            except OSError:
                break
            if not data:
                break
            for packet in decoder.feed(data):
                if packet.command == proto.CMD_SET_THRESHOLD and packet.payload:
                    self.threshold = packet.payload[0]
                elif packet.command == proto.CMD_SET_MODE and packet.payload:
                    self.mode = packet.payload[0]
                elif packet.command == proto.CMD_START_ANALYZE:
                    self.send_status()
                elif packet.command == proto.CMD_REQUEST_STATUS:
                    self.send_status()

    def send_status(self):
        area_pixels = int(np.count_nonzero(self.image)) if self.image is not None and self.image.size else 0
        area_x100 = int(round(area_pixels * 0.6605156214209273 * 0.6605156214209273 * 100))
        self.send_to_controls(proto.encode_status(self.mode, self.threshold, area_pixels,
                                                   area_x100, self.frame_id, 18000))

    def control_loop(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.host, self.control_port))
        server.listen(4)
        server.settimeout(0.2)
        try:
            while not self.stop_event.is_set():
                try:
                    client, _ = server.accept()
                except socket.timeout:
                    continue
                self.control_clients.append(client)
                threading.Thread(target=self.recv_client, args=(client,), daemon=True).start()
                self.send_status()
        finally:
            server.close()

    def image_loop(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.host, self.image_port))
        server.listen(4)
        server.settimeout(0.2)
        try:
            while not self.stop_event.is_set():
                try:
                    client, _ = server.accept()
                except socket.timeout:
                    continue
                decoder = proto.FrameDecoder()
                try:
                    while not self.stop_event.is_set():
                        data = client.recv(4096)
                        if not data:
                            break
                        for packet in decoder.feed(data):
                            if packet.command == proto.CMD_IMAGE_RAW:
                                result = self.assembler.feed(packet.payload)
                                if result is not None:
                                    frame_id, width, height, image = result
                                    self.frame_id = frame_id
                                    self.image = np.frombuffer(image, dtype=np.uint8).reshape(height, width)
                                    self.send_to_controls(proto.encode_packet(proto.CMD_ACK, bytes([proto.CMD_IMAGE_RAW, 0])))
                                    yy, xx = np.ogrid[:height, :width]
                                    mask = ((((xx - width/2) / (width*0.22)) ** 2 + ((yy - height/2) / (height*0.30)) ** 2) <= 1).astype(np.uint8)
                                    for mask_packet in proto.encode_mask_packets(mask, width, height, frame_id, 400):
                                        self.send_to_controls(mask_packet)
                                    self.send_status()
                finally:
                    client.close()
        finally:
            server.close()

    def run(self):
        print(f'Mock PS control server: {self.host}:{self.control_port}', flush=True)
        print(f'Mock PS image server:   {self.host}:{self.image_port}', flush=True)
        threading.Thread(target=self.control_loop, daemon=True).start()
        threading.Thread(target=self.image_loop, daemon=True).start()
        while not self.stop_event.is_set():
            self.send_status()
            time.sleep(0.2)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--control-port', type=int, default=5000)
    parser.add_argument('--image-port', type=int, default=5001)
    args = parser.parse_args()
    # ---- 干净退出: Ctrl+C(SIGINT) 和 launcher 发的 SIGTERM 都不再打 traceback ----
    def _bye(signum=None, frame=None):
        print('', flush=True)
        print('Mock PS stopped.', flush=True)
        sys.exit(0)

    try:
        import signal
        signal.signal(signal.SIGTERM, _bye)     # launch_gui.sh 的 cleanup 用的是这个
        signal.signal(signal.SIGINT, _bye)      # 你按 Ctrl+C 用的是这个
    except (ImportError, ValueError, OSError):
        pass

    try:
        MockPS(args.host, args.control_port, args.image_port).run()
    except KeyboardInterrupt:
        _bye()

if __name__ == '__main__':
    main()
