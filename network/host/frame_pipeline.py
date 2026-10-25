"""Bounded, full-duplex frame stream. Sending never waits for an individual reply.

One writer and one reader own each direction of a single TCP connection. The
caller bounds outstanding frames; firmware DDR rings and TCP windows provide
backpressure. A broken stream fails all outstanding futures, without replaying
frames under new identities or publishing partial pixels.
"""
from concurrent.futures import Future
from collections import deque
import queue
import secrets
import socket
import threading
import time

from frame_transfer import (INPUT_BYTES, OUTPUT_BYTES, META, META_MEDICAL, PERF, PERF_FAST,
    MAGIC, HEADER, ERROR, RemoteError, packet, crc, receive_header, recv_exact,
    decode_result_payload, decode_frame_performance)

HELLO_PIPE, PIPE_READY, PIPE_UPLOAD, PIPE_RESULT = 18, 19, 20, 22
PIPE_CREDIT = 23


class FramePipeline:
    def __init__(self, host, port, timeout=60, *, capacity=8, send_buffer=None,
                 send_chunk=None, send_pause=0):
        self.host, self.port, self.timeout = host, port, timeout
        self.capacity = capacity
        self.send_buffer = send_buffer
        if send_chunk is not None and (isinstance(send_chunk, bool)
                                       or not isinstance(send_chunk, int) or send_chunk < 1):
            raise ValueError('send_chunk must be a positive integer or None')
        if not 0 <= send_pause < float('inf'):
            raise ValueError('send_pause must be finite and nonnegative')
        self.send_chunk, self.send_pause = send_chunk, send_pause
        self._condition = threading.Condition()
        self._writes = queue.Queue(maxsize=capacity)
        self._pending = deque()
        self._socket = None
        self._threads = []
        self._closed = False
        self._error = None
        self._next_job = secrets.randbits(32) or 1
        self._credits = 0

    def _connect(self):
        sock = socket.create_connection((self.host, self.port), timeout=min(5, self.timeout))
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if self.send_buffer is not None:
                sock.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,self.send_buffer)
            sock.settimeout(self.timeout)
            sock.sendall(packet(HELLO_PIPE, self._next_job))
            if receive_header(sock, self._next_job) != (PIPE_READY, 0, 0, 6):
                raise ValueError('continuous stream protocol unavailable; rebuild and flash PS')
        except BaseException:
            sock.close()
            raise
        self._socket = sock
        for target, name in ((self._writer, 'fpga-stream-send'), (self._reader, 'fpga-stream-receive')):
            thread = threading.Thread(target=target, name=name, daemon=True)
            self._threads.append(thread)
            thread.start()

    def submit(self, source, mode):
        data = source['data']
        if len(data) != INPUT_BYTES or mode not in range(5):
            raise ValueError('invalid pipeline input or mode')
        with self._condition:
            if self._closed or self._error:
                raise RuntimeError(self._error or 'stream is closed')
            if len(self._pending) >= self.capacity:
                raise RuntimeError('pipeline capacity exhausted')
            if self._socket is None:
                self._connect()
            job = self._next_job
            self._next_job = (job + 1) & 0xffffffff or 1
            future = Future()
            context = {'job': job, 'mode': mode, 'data': data, 'future': future,
                       'started': time.perf_counter(), 'sent': threading.Event(),
                       'upload_queue_ms': 0.0, 'upload_ms': 0.0}
            self._pending.append(context)
            self._writes.put_nowait(context)
            self._condition.notify_all()
            return future

    def _fail(self, error):
        with self._condition:
            self._error = str(error)
            self._closed = True
            for context in self._pending:
                if not context['future'].done():
                    context['future'].set_exception(error)
                context['sent'].set()
            self._pending.clear()
            self._condition.notify_all()
        if self._socket is not None:
            try:
                self._socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def _writer(self):
        try:
            while True:
                try:
                    context = self._writes.get(timeout=.1)
                except queue.Empty:
                    if self._closed:
                        return
                    continue
                if self._closed:
                    return
                with self._condition:
                    if not self._condition.wait_for(lambda:self._credits>0 or self._closed, self.timeout):
                        raise TimeoutError('waiting for a free FPGA input slot timed out')
                    if self._closed:
                        return
                    self._credits -= 1
                started = time.perf_counter()
                context['upload_queue_ms'] = (started-context['started'])*1000
                data = context['data']
                payload = packet(PIPE_UPLOAD, context['job'], len(data), crc(data), context['mode']) + data
                if self.send_chunk is None:
                    self._socket.sendall(payload)
                else:
                    for offset in range(0, len(payload), self.send_chunk):
                        self._socket.sendall(payload[offset:offset+self.send_chunk])
                        if self.send_pause and offset+self.send_chunk < len(payload):
                            time.sleep(self.send_pause)
                context['upload_ms'] = (time.perf_counter()-started)*1000
                context['sent'].set()
        except Exception as error:
            self._fail(error)

    def _reader(self):
        try:
            while True:
                with self._condition:
                    self._condition.wait_for(lambda: self._pending or self._closed)
                    if self._closed:
                        return
                    context = self._pending[0]
                job = context['job']
                deadline = time.monotonic() + max(0, self.timeout-(time.perf_counter()-context['started']))
                started = time.perf_counter()
                kind, length, checksum, mode = self._result_header(job, deadline)
                header_received = time.perf_counter()
                if (kind != PIPE_RESULT or length - OUTPUT_BYTES not in (META.size, META_MEDICAL.size)
                        or mode != context['mode']):
                    raise ValueError('pipeline result id/length/mode mismatch')
                payload = recv_exact(self._socket, length, deadline)
                received = time.perf_counter()
                if crc(payload) != checksum:
                    raise ValueError('FPGA result CRC mismatch')
                readback, raw = decode_result_payload(payload, mode)
                if raw[3::4].count(255) != 65536:
                    raise ValueError('FPGA RGBA alpha must be 255')
                validated = time.perf_counter()
                kind, length, checksum, extra = receive_header(self._socket, job, deadline)
                if kind != PERF_FAST or length != PERF.size or extra:
                    raise ValueError('missing pipeline performance trailer')
                performance = recv_exact(self._socket, length, deadline)
                if crc(performance) != checksum:
                    raise ValueError('FPGA performance trailer CRC mismatch')
                readback['ps_detail'] = decode_frame_performance(performance)
                context['sent'].wait(self.timeout)
                finished = time.perf_counter()
                result = {'ok': True, 'job': job, 'mode': mode, 'raw': raw, 'frames': 1,
                    'readback': readback, 'timings_ms': {
                        'transfer_ms': (finished-context['started'])*1000,
                        'upload_queue_ms': context['upload_queue_ms'],
                        'upload_send_ms': context['upload_ms'],
                        'wait_header_ms': (header_received-started)*1000,
                        'result_receive_ms': (received-header_received)*1000,
                        'host_validate_ms': (validated-received)*1000,
                        'perf_receive_ms': (finished-validated)*1000,
                        'readback_ms': 0.0, 'pc_files_ms': 0.0}}
                with self._condition:
                    if self._closed:
                        return
                    self._pending.popleft()
                    context['future'].set_result(result)
                    self._condition.notify_all()
        except Exception as error:
            self._fail(error)

    def _result_header(self, job, deadline):
        while True:
            magic,kind,received_job,length,checksum,extra=HEADER.unpack(
                recv_exact(self._socket,HEADER.size,deadline))
            if magic!=MAGIC:
                raise ValueError('FPGA response magic mismatch')
            if kind==PIPE_CREDIT:
                if received_job or length or checksum or extra not in range(1,5):
                    raise ValueError('invalid FPGA input-slot grant')
                with self._condition:
                    if self._credits+extra>4:
                        raise ValueError('FPGA granted more slots than its input ring')
                    self._credits+=extra;self._condition.notify_all()
                continue
            if kind==ERROR:
                if length>512:raise ValueError('invalid FPGA error response')
                raise RemoteError(extra,recv_exact(self._socket,length,deadline).decode('utf-8','replace'))
            if received_job!=job:
                raise ValueError('FPGA result job id mismatch')
            return kind,length,checksum,extra

    def close(self):
        with self._condition:
            self._closed = True
            for context in self._pending:
                if not context['future'].done():
                    context['future'].set_exception(ConnectionError('stream closed'))
                context['sent'].set()
            self._pending.clear()
            self._condition.notify_all()
        if self._socket is not None:
            try:
                self._socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._socket.close()
        for thread in self._threads:
            if thread is not threading.current_thread():
                thread.join(2)
