#!/usr/bin/env python3
import argparse
import socket
import time
from pathlib import Path
import numpy as np
from PIL import Image
import protocol as proto


def load_gray(path):
    path = Path(path)
    if path.suffix.lower() == '.bin':
        data = np.fromfile(path, dtype=np.uint8)
        if data.size != 256 * 256:
            raise ValueError('BIN must be 65536 bytes')
        return data
    image = Image.open(path).convert('L').resize((256, 256), Image.Resampling.BILINEAR)
    return np.asarray(image, dtype=np.uint8).reshape(-1)


def send_image(sock, image_bytes, frame_id, chunk_size=4096):
    packets = proto.encode_image_packets(bytes(image_bytes), 256, 256, frame_id, chunk_size)
    start = time.perf_counter()
    for packet in packets:
        sock.sendall(packet)
    elapsed = time.perf_counter() - start
    return len(packets), elapsed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='192.168.1.10')
    parser.add_argument('--port', type=int, default=5001)
    parser.add_argument('--image', required=True)
    parser.add_argument('--frame-id', type=int, default=1)
    parser.add_argument('--chunk-size', type=int, default=4096)
    parser.add_argument('--loop', action='store_true')
    parser.add_argument('--fps', type=float, default=1.0)
    args = parser.parse_args()
    image = load_gray(args.image)
    frame_id = args.frame_id
    while True:
        with socket.create_connection((args.host, args.port), timeout=5.0) as sock:
            packets, elapsed = send_image(sock, image, frame_id, args.chunk_size)
        print({'frame_id': frame_id, 'packets': packets, 'bytes': len(image),
               'elapsed_ms': round(elapsed * 1000, 3),
               'Mbps': round(len(image) * 8 / max(elapsed, 1e-9) / 1e6, 2)})
        frame_id = (frame_id + 1) & 0xFFFF
        if not args.loop:
            break
        time.sleep(max(0.0, 1.0 / args.fps - elapsed))


if __name__ == '__main__':
    main()
