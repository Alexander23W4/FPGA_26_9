"""One FPGA transaction: upload DDR input, receive result, save, then acknowledge."""
from __future__ import annotations
import binascii
import base64
from datetime import datetime
import hashlib
import io
import os
from pathlib import Path
import secrets
import socket
import struct
import threading
from PIL import Image

MAGIC = 0x48434631  # HCF1, network byte order
HEADER = struct.Struct('!6I')
UPLOAD, RESULT, SAVED, DONE, ERROR, RESUME = range(1, 7)
INPUT_BYTES = 65536
OUTPUT_BYTES = 262144
MODE_NAMES = ('denoise', 'contour', 'mask', 'overlay', 'heat')

class RemoteError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

class ResultSaveError(RuntimeError):
    pass

def crc(data):
    return binascii.crc32(data) & 0xffffffff

def packet(kind, job, length=0, checksum=0, extra=0):
    return HEADER.pack(MAGIC, kind, job, length, checksum, extra)

def recv_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(min(65536, count-len(data)))
        if not block:
            raise ConnectionError('FPGA closed the connection before a complete response')
        data.extend(block)
    return bytes(data)

def receive_header(sock, job):
    magic, kind, received_job, length, checksum, extra = HEADER.unpack(recv_exact(sock, HEADER.size))
    if magic != MAGIC or received_job != job:
        raise ValueError('FPGA response magic/job id mismatch')
    if kind == ERROR:
        if length > 512:
            raise ValueError('invalid FPGA error response')
        raise RemoteError(extra, recv_exact(sock, length).decode('utf-8', 'replace'))
    return kind, length, checksum, extra

def result_image(raw, mode):
    if len(raw) != OUTPUT_BYTES or mode not in range(5) or any(m != mode for m in raw[3::4]):
        raise ValueError('FPGA result length/mode is invalid')
    # DDR words are little endian: bytes B,G,R,mode for every pixel.
    rgb = bytearray(256*256*3)
    rgb[0::3], rgb[1::3], rgb[2::3] = raw[2::4], raw[1::4], raw[0::4]
    return Image.frombytes('RGB', (256, 256), bytes(rgb))


def saved_result_png(files, mode, checksum):
    """Read this job's exact BIN, never an older file matching the input stem."""
    raw = Path(files['bin']).read_bytes()
    if crc(raw) != checksum or not Path(files['png']).is_file():
        raise ValueError('saved FPGA result is missing or has an invalid CRC')
    output = io.BytesIO()
    result_image(raw, mode).save(output, format='PNG')
    return base64.b64encode(output.getvalue()).decode('ascii')


def save_result(raw, filename, mode, job, folder):
    image = result_image(raw, mode)
    stem = Path(filename.replace('\\', '/')).stem
    stem = ''.join(c if c.isalnum() or c in '_-' else '_' for c in stem)[:80] or 'image'
    root = Path(folder)
    root.mkdir(parents=True, exist_ok=True)
    name = '%s_%s_%s_%08x' % (stem, MODE_NAMES[mode], datetime.now().strftime('%Y%m%d_%H%M%S_%f'), job)
    binary, png = root/(name+'.bin'), root/(name+'.png')
    temps = (root/(name+'.bin.part'), root/(name+'.png.part'))
    try:
        with temps[0].open('xb') as output:
            output.write(raw); output.flush(); os.fsync(output.fileno())
        with temps[1].open('xb') as output:
            image.save(output, format='PNG')
            output.flush(); os.fsync(output.fileno())
        os.replace(temps[0], binary)
        os.replace(temps[1], png)
    finally:
        for temp in temps:
            temp.unlink(missing_ok=True)
    return {'bin': str(binary.resolve()), 'png': str(png.resolve())}

class FrameTransferClient:
    def __init__(self, host='192.168.1.10', port=5002, folder='E:/fpga_done_img', timeout=60):
        self.host, self.port, self.folder, self.timeout = host, port, folder, timeout
        self.pending = None
        self.lock = threading.Lock()

    def transfer(self, image, filename, expected_mode=None):
        if len(image) != INPUT_BYTES or Path(filename).suffix.lower() != '.bin':
            raise ValueError('input must be a 256x256x8-bit BIN of exactly 65536 bytes')
        if expected_mode is not None and expected_mode not in range(5):
            raise ValueError('expected processing mode must be 0..4')
        if not self.lock.acquire(blocking=False):
            raise RuntimeError('another FPGA frame transaction is in progress')
        try:
            digest = hashlib.sha256(image).digest()
            if self.pending is not None and self.pending['digest'] != digest:
                raise RuntimeError('上一张图片的回传尚未确认，请先重新发送同一张图片以恢复任务')
            if self.pending is not None and self.pending['expected_mode'] != expected_mode:
                raise RuntimeError('上一处理模式尚未确认，请先重试原来的处理任务')
            if self.pending is None:
                self.pending = {'job': secrets.randbits(32) or 1, 'digest': digest,
                                'filename': filename, 'uploaded': False, 'files': None,
                                'expected_mode': expected_mode}
            context = self.pending
            job = context['job']
            for attempt in range(3):
                try:
                    with socket.create_connection((self.host, self.port), timeout=5) as sock:
                        sock.settimeout(self.timeout)
                        if context['uploaded']:
                            sock.sendall(packet(RESUME, job))
                        else:
                            # Retain the job for RESUME even if the connection fails midway.
                            context['uploaded'] = True
                            sock.sendall(packet(UPLOAD, job, INPUT_BYTES, crc(image)))
                            sock.sendall(image)
                        kind, length, checksum, mode = receive_header(sock, job)
                        if kind == DONE:
                            if (context['files'] is None or length != 0 or
                                checksum != context.get('crc') or mode != context.get('mode')):
                                raise ValueError('FPGA confirmed a job without locally saved files')
                        else:
                            if kind != RESULT or length != OUTPUT_BYTES or mode not in range(5):
                                raise ValueError('unexpected FPGA result header')
                            if expected_mode is not None and mode != expected_mode:
                                raise ValueError('FPGA result mode mismatch: requested %d, got %d' % (expected_mode, mode))
                            raw = recv_exact(sock, length)
                            if crc(raw) != checksum:
                                raise ValueError('FPGA result CRC mismatch')
                            files = context['files']
                            if (files is None or not Path(files['png']).is_file() or
                                not Path(files['bin']).is_file() or crc(Path(files['bin']).read_bytes()) != checksum):
                                try:
                                    context['files'] = save_result(raw, context['filename'], mode, job, self.folder)
                                except OSError as error:
                                    raise ResultSaveError('PC 保存失败，FPGA 尚未收到确认：'+str(error)) from error
                            context['crc'], context['mode'] = checksum, mode
                            # Reopen and validate the completed BIN before PS writes receive_done.
                            saved_result_png(context['files'], mode, checksum)
                            sock.sendall(packet(SAVED, job, OUTPUT_BYTES, checksum, mode))
                            kind, length, done_crc, done_mode = receive_header(sock, job)
                            if kind != DONE or length != 0 or done_crc != context['crc'] or done_mode != context['mode']:
                                raise ValueError('FPGA did not confirm the PC save acknowledgement')
                        files = context['files']
                        # GUI loads the on-disk result only after receive_done is confirmed.
                        preview = saved_result_png(files, context['mode'], context['crc'])
                        self.pending = None
                        return {'ok': True, 'frames': 1, 'bytes': INPUT_BYTES,
                                'output_bytes': OUTPUT_BYTES, 'job': job, 'files': files,
                                'mode': context['mode'], 'image': preview,
                                'log': '网口上传 DDR → PL → S2MM → DDR → PC 保存完成\n'+files['png']+'\n'+files['bin']}
                except RemoteError as error:
                    if error.code == 1 and attempt < 2:
                        context['uploaded'] = False
                        continue
                    if error.code == 2:
                        self.pending = None
                    raise
                except (OSError, ConnectionError):
                    if attempt == 2:
                        raise
            raise RuntimeError('unreachable')
        finally:
            self.lock.release()
