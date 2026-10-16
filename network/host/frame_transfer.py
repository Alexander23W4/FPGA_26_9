"""Upload or redraw one FPGA frame, durably save its result, then acknowledge."""
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
import time
from PIL import Image

MAGIC = 0x48434631  # HCF1, network byte order
HEADER = struct.Struct('!6I')
UPLOAD, RESULT, SAVED, DONE, ERROR, RESUME, RENDER, CONFIGURED = range(1, 9)
CANCEL = 9  # One-way: abandon this job; no result/acknowledgement is awaited.
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

def remaining_time(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('FPGA frame transaction deadline exceeded')
    return remaining


def recv_exact(sock, count, deadline=None):
    data = bytearray()
    while len(data) < count:
        if deadline is not None:
            sock.settimeout(remaining_time(deadline))
        block = sock.recv(min(65536, count-len(data)))
        if not block:
            raise ConnectionError('FPGA closed the connection before a complete response')
        data.extend(block)
    return bytes(data)

def receive_header(sock, job, deadline=None):
    magic, kind, received_job, length, checksum, extra = HEADER.unpack(recv_exact(sock, HEADER.size, deadline))
    if magic != MAGIC or received_job != job:
        raise ValueError('FPGA response magic/job id mismatch')
    if kind == ERROR:
        if length > 512:
            raise ValueError('invalid FPGA error response')
        raise RemoteError(extra, recv_exact(sock, length, deadline).decode('utf-8', 'replace'))
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
        return self._transaction(UPLOAD, image, filename, expected_mode)

    def render(self, mode, filename='image.bin'):
        """Reuse the PL frame. Firmware arms S2MM before changing display mode."""
        if mode not in range(5):
            raise ValueError('processing mode must be 0..4')
        return self._transaction(RENDER, b'', filename, mode)

    def _cancel_job(self, job):
        # A fresh connection also drops a partially uploaded body at the PS.
        # This is best-effort cleanup; never wait for the abandoned result.
        try:
            with socket.create_connection((self.host, self.port), timeout=1) as sock:
                sock.settimeout(1)
                sock.sendall(packet(CANCEL, job))
        except OSError:
            pass

    def _transaction(self, operation, image, filename, expected_mode):
        if not self.lock.acquire(blocking=False):
            raise RuntimeError('another FPGA frame transaction is in progress')
        try:
            digest = hashlib.sha256(image).digest()
            if self.pending is not None and (self.pending['digest'] != digest or self.pending['operation'] != operation):
                raise RuntimeError('上一张图片的回传尚未确认，请先重新发送同一张图片以恢复任务')
            if self.pending is not None and self.pending['expected_mode'] != expected_mode:
                raise RuntimeError('上一处理模式尚未确认，请先重试原来的处理任务')
            if self.pending is None:
                self.pending = {'job': secrets.randbits(32) or 1, 'digest': digest,
                                'filename': filename, 'uploaded': False, 'files': None,
                                'expected_mode': expected_mode, 'operation': operation}
            context = self.pending
            job = context['job']
            deadline = time.monotonic() + self.timeout
            for attempt in range(3):
                try:
                    with socket.create_connection((self.host, self.port), timeout=min(5, remaining_time(deadline))) as sock:
                        sock.settimeout(remaining_time(deadline))
                        if context['uploaded']:
                            sock.sendall(packet(RESUME, job))
                        else:
                            # Retain the job for RESUME even if the connection fails midway.
                            context['uploaded'] = True
                            if operation == UPLOAD:
                                sock.sendall(packet(UPLOAD, job, INPUT_BYTES, crc(image)))
                                sock.settimeout(remaining_time(deadline))
                                sock.sendall(image)
                            else:
                                sock.sendall(packet(RENDER, job, extra=expected_mode))
                        kind, length, checksum, mode = receive_header(sock, job, deadline)
                        if kind == CONFIGURED:
                            if operation != RENDER or length or checksum or mode != expected_mode:
                                raise ValueError('invalid FPGA configuration response')
                            self.pending = None
                            return {'ok': True, 'frames': 0, 'bytes': 0, 'mode': mode,
                                    'output_bytes': 0, 'log': '显示模式已设置，等待选择 BIN 图像'}
                        if kind == DONE:
                            if (context['files'] is None or length != 0 or
                                checksum != context.get('crc') or mode != context.get('mode')):
                                raise ValueError('FPGA confirmed a job without locally saved files')
                        else:
                            if kind != RESULT or length != OUTPUT_BYTES or mode not in range(5):
                                raise ValueError('unexpected FPGA result header')
                            if expected_mode is not None and mode != expected_mode:
                                raise ValueError('FPGA result mode mismatch: requested %d, got %d' % (expected_mode, mode))
                            raw = recv_exact(sock, length, deadline)
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
                            # Reopen and validate before releasing PS result-buffer ownership.
                            saved_result_png(context['files'], mode, checksum)
                            sock.settimeout(remaining_time(deadline))
                            sock.sendall(packet(SAVED, job, OUTPUT_BYTES, checksum, mode))
                            kind, length, done_crc, done_mode = receive_header(sock, job, deadline)
                            if kind != DONE or length != 0 or done_crc != context['crc'] or done_mode != context['mode']:
                                raise ValueError('FPGA did not confirm the PC save acknowledgement')
                        files = context['files']
                        # GUI loads the on-disk result after the PS confirms the save.
                        preview = saved_result_png(files, context['mode'], context['crc'])
                        self.pending = None
                        return {'ok': True, 'frames': 1, 'bytes': len(image),
                                'output_bytes': OUTPUT_BYTES, 'job': job, 'files': files,
                                'mode': context['mode'], 'image': preview,
                                'log': ('网口上传 DDR → PL' if operation == UPLOAD else '复用 PL 图像，更新显示模式')+
                                       ' → S2MM → DDR → PC 保存完成\n'+files['png']+'\n'+files['bin']}
                except RemoteError as error:
                    if 'timeout' in str(error).lower():
                        raise TimeoutError(str(error)) from error
                    if error.code == 1 and attempt < 2:
                        context['uploaded'] = False
                        continue
                    if error.code == 2:
                        self.pending = None
                    raise
                except TimeoutError:
                    raise  # A timeout ends this job; do not RESUME or retry it.
                except (OSError, ConnectionError):
                    if attempt == 2:
                        raise
            raise RuntimeError('unreachable')
        except TimeoutError as error:
            abandoned = self.pending
            self.pending = None
            if abandoned is not None and abandoned['uploaded']:
                self._cancel_job(abandoned['job'])
            raise TimeoutError('等待 FPGA 回传超时，本次任务已取消，请重新操作') from error
        finally:
            self.lock.release()
