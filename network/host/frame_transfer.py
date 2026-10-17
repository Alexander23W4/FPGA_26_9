"""FPGA TCP frames: durable single-image jobs and memory-only stream reception."""
from __future__ import annotations
import binascii
import contextlib
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
UPLOAD_FAST, RESULT_FAST, RENDER_FAST = 10, 11, 13
HELLO_FAST, FAST_READY = 14, 15
RESULT_RGBA = 16
PERF_FAST = 17
META = struct.Struct('!14I')  # v4: same registers, followed by a PERF_FAST message
PERF = struct.Struct('!12I')
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
    if len(raw) != OUTPUT_BYTES or mode not in range(5):
        raise ValueError('FPGA result length/mode is invalid')
    if raw[3::4].count(255) == 65536:
        return Image.frombytes('RGBA', (256, 256), raw).convert('RGB')
    if raw[3::4].count(mode) != 65536:
        raise ValueError('FPGA result length/mode is invalid')
    # DDR words are little endian: bytes B,G,R,mode for every pixel.
    rgb = bytearray(256*256*3)
    rgb[0::3], rgb[1::3], rgb[2::3] = raw[2::4], raw[1::4], raw[0::4]
    return Image.frombytes('RGB', (256, 256), bytes(rgb))


def decode_frame_metadata(data, mode):
    (version, system, threshold_mode, video, actual, manual, lesion, alpha,
     rx_us, setup_us, pl_us, interval_cycles, stall_cycles, interval_seq) = META.unpack(data)
    if (version not in (4, 5) or system > 1 or threshold_mode > 1 or video != mode or
            actual > 255 or manual > 255 or lesion > 65536 or alpha > 100):
        raise ValueError('invalid FPGA frame register snapshot')
    return {'ok': True, 'system_mode': system, 'mode': threshold_mode,
            'video_mode': video, 'actual_threshold': actual, 'threshold': manual,
            'lesion_pixels': lesion, 'lesion_mm2': '%.3f' % (lesion * 0.436280886141),
            'mask_transparency': alpha,
            'ps_timings_ms': {'receive': rx_us/1000, 'setup': setup_us/1000, 'pl_to_ddr': pl_us/1000},
            'pl_interval': {'sequence': interval_seq, 'elapsed_ms': interval_cycles/(1000 if version == 5 else 25200),
                            'write_stall_ms': stall_cycles/(1000 if version == 5 else 25200)},
            'log': 'register snapshot received with frame over TCP'}


def decode_frame_performance(data):
    (version, check, output_crc, tx_queue, tx_copy, calls, waits, input_crc,
     rx_copy, window, send_buffer, optimized) = PERF.unpack(data)
    if version != 1 or optimized > 1 or not 0 < window <= 65535 or not 0 < send_buffer <= 65535:
        raise ValueError('invalid FPGA performance trailer')
    return {'output_check': check/1000, 'output_crc': output_crc/1000,
            'tcp_enqueue': tx_queue/1000, 'tcp_copy': tx_copy/1000,
            'input_crc': input_crc/1000, 'rx_copy': rx_copy/1000,
            'tcp_write_calls': calls, 'tcp_wait_polls': waits,
            'tcp_window_bytes': window, 'tcp_send_bytes': send_buffer, 'optimized': bool(optimized)}


def saved_result_png(files, mode, checksum):
    """Read this job's exact BIN, never an older file matching the input stem."""
    raw = Path(files['bin']).read_bytes()
    if crc(raw) != checksum or not Path(files['png']).is_file():
        raise ValueError('saved FPGA result is missing or has an invalid CRC')
    result_image(raw, mode)  # Validate actual pixels before the save acknowledgement.
    return base64.b64encode(Path(files['png']).read_bytes()).decode('ascii')


def normalize_result_name(result_name):
    """Accept a portable relative BIN path without Windows path aliases."""
    if result_name is None:
        return None
    try:
        name = os.fspath(result_name)
    except TypeError as error:
        raise ValueError('result_name must be a safe relative BIN path') from error
    if not isinstance(name, str):
        raise ValueError('result_name must be a safe relative BIN path')
    name = name.replace('\\', '/')
    parts = name.split('/')
    reserved = {'CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$'}
    reserved.update(prefix + digit for prefix in ('COM', 'LPT')
                    for digit in '123456789\u00b9\u00b2\u00b3')
    for part in parts:
        if (not part or part in ('.', '..') or part.endswith((' ', '.')) or
                any(ord(char) < 32 or char in '<>:"|?*' for char in part) or
                part.split('.')[0].rstrip(' ').upper() in reserved):
            raise ValueError('result_name must be a safe relative BIN path')
    if Path(parts[-1]).suffix.lower() != '.bin':
        raise ValueError('result_name must end in .bin')
    return '/'.join(parts)


def stable_result_paths(folder, result_name):
    """Reject existing symlinks/junctions that would write outside the result root."""
    root = Path(folder).resolve()
    binary = root.joinpath(*result_name.split('/'))
    png = binary.with_suffix('.png')
    for path in (binary, png):
        try:
            path.resolve().relative_to(root)
        except ValueError as error:
            raise ValueError('result_name resolves outside the result folder') from error
    return binary, png


def save_result(raw, filename, mode, job, folder, *, result_name=None):
    image = result_image(raw, mode)
    result_name = normalize_result_name(result_name)
    root = Path(folder)
    if result_name is None:
        stem = Path(filename.replace('\\', '/')).stem
        stem = ''.join(c if c.isalnum() or c in '_-' else '_' for c in stem)[:80] or 'image'
        name = '%s_%s_%s_%08x' % (stem, MODE_NAMES[mode], datetime.now().strftime('%Y%m%d_%H%M%S_%f'), job)
        binary, png = root/(name+'.bin'), root/(name+'.png')
    else:
        binary, png = stable_result_paths(root, result_name)
    binary.parent.mkdir(parents=True, exist_ok=True)
    if result_name is not None:
        # Check again after directory creation, including existing file symlinks.
        binary, png = stable_result_paths(root, result_name)
    temps = tuple(path.with_name(path.name + '.%08x.part' % job) for path in (binary, png))
    try:
        with temps[0].open('xb') as output:
            output.write(raw); output.flush(); os.fsync(output.fileno())
        with temps[1].open('xb') as output:
            image.save(output, format='PNG', compress_level=1)
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
        self._socket = None
        self._fast_capable = False

    def close(self):
        sock, self._socket = getattr(self, '_socket', None), None
        self._fast_capable = False
        if sock is not None:
            sock.close()

    def __del__(self):
        self.close()

    @contextlib.contextmanager
    def _session(self, deadline):
        try:
            if self._socket is None:
                self._socket = socket.create_connection((self.host, self.port),
                    timeout=min(5, remaining_time(deadline)))
                self._socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._socket.settimeout(remaining_time(deadline))
            yield self._socket
        except BaseException:
            self.close()
            raise

    def transfer(self, image, filename, expected_mode=None, *, result_name=None):
        if len(image) != INPUT_BYTES or Path(filename).suffix.lower() != '.bin':
            raise ValueError('input must be a 256x256x8-bit BIN of exactly 65536 bytes')
        if expected_mode is not None and expected_mode not in range(5):
            raise ValueError('expected processing mode must be 0..4')
        return self._transaction(UPLOAD, image, filename, expected_mode, result_name)

    def render(self, mode, filename='image.bin', *, result_name=None):
        """Reuse the PL frame. Firmware arms S2MM before changing display mode."""
        if mode not in range(5):
            raise ValueError('processing mode must be 0..4')
        return self._transaction(RENDER, b'', filename, mode, result_name)

    def receive_frame(self, image=None, mode=None):
        """Return owned RGBA + metrics; no application ACK, disk work or PNG encoding."""
        if image is not None and len(image) != INPUT_BYTES:
            raise ValueError('input must contain exactly 65536 bytes')
        if image is None and mode not in range(5):
            raise ValueError('render mode must be 0..4')
        operation = UPLOAD_FAST if image is not None else RENDER_FAST
        image = b'' if image is None else image
        if not self.lock.acquire(blocking=False):
            raise RuntimeError('another FPGA transaction is in progress')
        started = time.perf_counter()
        deadline = time.monotonic() + self.timeout
        try:
            key = (operation, hashlib.sha256(image).digest(), mode)
            if self.pending is not None and self.pending.get('fast_key') != key:
                raise RuntimeError('上一帧尚未确认，请先重试原图及模式')
            if self.pending is None:
                self.pending = {'fast_key': key, 'job': secrets.randbits(32) or 1,
                                'uploaded': False, 'raw': None}
            context = self.pending
            job = context['job']
            for attempt in range(3):
                try:
                    upload_ms = 0.0
                    with self._session(deadline) as sock:
                        if not self._fast_capable:
                            sock.sendall(packet(HELLO_FAST, job))
                            hello = receive_header(sock, job, deadline)
                            if hello != (FAST_READY, 0, 0, 4):
                                raise ValueError('stream protocol unavailable; rebuild and flash PS firmware')
                            self._fast_capable = True
                        if context['uploaded']:
                            sock.sendall(packet(RESUME, job))
                        else:
                            context['uploaded'] = True
                            upload_started = time.perf_counter()
                            sock.sendall(packet(operation, job, len(image), crc(image), mode or 0) + image)
                            upload_ms = (time.perf_counter()-upload_started)*1000
                        wait_started = time.perf_counter()
                        kind, length, checksum, returned_mode = receive_header(sock, job, deadline)
                        header_received = time.perf_counter()
                        if kind != RESULT_FAST or length != OUTPUT_BYTES + META.size or returned_mode not in range(5):
                            raise ValueError('unexpected stream protocol; rebuild and flash PL/PS')
                        if mode is not None and returned_mode != mode:
                            raise ValueError('FPGA result mode mismatch')
                        payload = recv_exact(sock, length, deadline)
                        payload_received = time.perf_counter()
                        if crc(payload) != checksum:
                            raise ValueError('FPGA result CRC mismatch')
                        readback = decode_frame_metadata(payload[:META.size], returned_mode)
                        raw = payload[META.size:]
                        if raw[3::4].count(255) != 65536:
                            raise ValueError('FPGA RGBA alpha must be 255')
                        validated = time.perf_counter()
                        kind, perf_length, perf_crc, extra = receive_header(sock, job, deadline)
                        if kind != PERF_FAST or perf_length != PERF.size or extra:
                            raise ValueError('missing FPGA performance trailer; rebuild PS')
                        perf = recv_exact(sock, perf_length, deadline)
                        if crc(perf) != perf_crc:
                            raise ValueError('FPGA performance trailer CRC mismatch')
                        readback['ps_detail'] = decode_frame_performance(perf)
                        context.update(raw=raw, readback=readback, crc=checksum, mode=returned_mode)
                        self.pending = None
                        return {'ok': True, 'job': job, 'mode': context['mode'], 'raw': context['raw'],
                                'readback': context['readback'], 'frames': 1,
                                'timings_ms': {'transfer_ms': (time.perf_counter() - started) * 1000,
                                               'upload_send_ms': upload_ms,
                                               'wait_header_ms': (header_received-wait_started)*1000,
                                               'result_receive_ms': (payload_received-header_received)*1000,
                                               'host_validate_ms': (validated-payload_received)*1000,
                                               'perf_receive_ms': (time.perf_counter()-validated)*1000,
                                               'readback_ms': 0.0, 'pc_files_ms': 0.0}}
                except RemoteError as error:
                    if 'timeout' in str(error).lower():
                        raise TimeoutError(str(error)) from error
                    if error.code == 1 and attempt < 2:
                        context.update(uploaded=False, raw=None)
                        continue
                    if error.code == 2:
                        self.pending = None
                    raise
                except TimeoutError:
                    raise
                except (OSError, ConnectionError):
                    if attempt == 2:
                        raise
            raise RuntimeError('unreachable')
        except TimeoutError as error:
            abandoned, self.pending = self.pending, None
            if abandoned is not None and abandoned['uploaded']:
                self._cancel_job(abandoned['job'])
            raise TimeoutError('等待 FPGA 回传超时，本次任务已取消，请重新操作') from error
        finally:
            self.lock.release()

    def _cancel_job(self, job):
        # A fresh connection also drops a partially uploaded body at the PS.
        # This is best-effort cleanup; never wait for the abandoned result.
        self.close()
        try:
            with socket.create_connection((self.host, self.port), timeout=1) as sock:
                sock.settimeout(1)
                sock.sendall(packet(CANCEL, job))
        except OSError:
            pass

    def _transaction(self, operation, image, filename, expected_mode, result_name=None):
        started = time.perf_counter()
        timings = {'save_ms': 0.0, 'preview_ms': 0.0}
        result_name = normalize_result_name(result_name)
        if result_name is not None:
            stable_result_paths(self.folder, result_name)
        if not self.lock.acquire(blocking=False):
            raise RuntimeError('another FPGA frame transaction is in progress')
        try:
            digest = hashlib.sha256(image).digest()
            if self.pending is not None and (self.pending['digest'] != digest or self.pending['operation'] != operation):
                raise RuntimeError('上一张图片的回传尚未确认，请先重新发送同一张图片以恢复任务')
            if self.pending is not None and self.pending['expected_mode'] != expected_mode:
                raise RuntimeError('上一处理模式尚未确认，请先重试原来的处理任务')
            if self.pending is not None and self.pending.get('result_name') != result_name:
                raise RuntimeError('上一回传任务的保存路径尚未确认，请先重试原来的处理任务')
            if self.pending is None:
                self.pending = {'job': secrets.randbits(32) or 1, 'digest': digest,
                                'filename': filename, 'uploaded': False, 'files': None,
                                'expected_mode': expected_mode, 'operation': operation,
                                'result_name': result_name}
            context = self.pending
            job = context['job']
            deadline = time.monotonic() + self.timeout
            for attempt in range(3):
                try:
                    with self._session(deadline) as sock:
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
                            if kind not in (RESULT, RESULT_RGBA) or length != OUTPUT_BYTES or mode not in range(5):
                                raise ValueError('unexpected FPGA result header')
                            if expected_mode is not None and mode != expected_mode:
                                raise ValueError('FPGA result mode mismatch: requested %d, got %d' % (expected_mode, mode))
                            raw = recv_exact(sock, length, deadline)
                            if crc(raw) != checksum:
                                raise ValueError('FPGA result CRC mismatch')
                            if kind == RESULT_RGBA and raw[3::4].count(255) != 65536:
                                raise ValueError('FPGA RGBA alpha must be 255')
                            before_save = time.perf_counter()
                            files = context['files']
                            if (files is None or not Path(files['png']).is_file() or
                                not Path(files['bin']).is_file() or crc(Path(files['bin']).read_bytes()) != checksum):
                                try:
                                    if context['result_name'] is None:
                                        context['files'] = save_result(raw, context['filename'], mode, job, self.folder)
                                    else:
                                        context['files'] = save_result(raw, context['filename'], mode, job, self.folder,
                                                                       result_name=context['result_name'])
                                except OSError as error:
                                    raise ResultSaveError('PC 保存失败，FPGA 尚未收到确认：'+str(error)) from error
                            context['crc'], context['mode'] = checksum, mode
                            # Reopen and validate before releasing PS result-buffer ownership.
                            saved_result_png(context['files'], mode, checksum)
                            timings['save_ms'] += (time.perf_counter() - before_save) * 1000
                            sock.settimeout(remaining_time(deadline))
                            sock.sendall(packet(SAVED, job, OUTPUT_BYTES, checksum, mode))
                            kind, length, done_crc, done_mode = receive_header(sock, job, deadline)
                            if kind != DONE or length != 0 or done_crc != context['crc'] or done_mode != context['mode']:
                                raise ValueError('FPGA did not confirm the PC save acknowledgement')
                        files = context['files']
                        # GUI loads the on-disk result after the PS confirms the save.
                        before_preview = time.perf_counter()
                        preview = saved_result_png(files, context['mode'], context['crc'])
                        timings['preview_ms'] += (time.perf_counter() - before_preview) * 1000
                        timings['total_ms'] = (time.perf_counter() - started) * 1000
                        self.pending = None
                        return {'ok': True, 'frames': 1, 'bytes': len(image),
                                'output_bytes': OUTPUT_BYTES, 'job': job, 'files': files,
                                'mode': context['mode'], 'image': preview, 'timings_ms': timings,
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
