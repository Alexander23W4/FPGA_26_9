"""Bounded, memory-only scheduling for sequential or pipelined FPGA transfers.

The transfer worker owns dispatch: neither HTTP response delivery nor the GUI
consuming a preview can delay the next frame already in the source queue.
"""
from __future__ import annotations

from collections import deque
import math
from queue import Full
import threading
import time


FRAME_BYTES = 256 * 256


class QueueFull(Full):
    """The pending-frame queue is full; the caller may retry this sequence."""


class QueuedStream:
    """Run ``process(source, mode)`` sequentially, with bounded preview storage.

    ``on_close()`` is called exactly once by the worker, including on transfer
    failure or lease expiry. A newly created session is paused for pre-filling.
    ``stopped`` becomes true only after that callback has finished.
    """

    def __init__(self, process, on_close, *, capacity=4, preview_capacity=2,
                 lease_seconds=30.0, mode=0, pipeline=None, on_result=None):
        if (pipeline is None and not callable(process)) or not callable(on_close):
            raise TypeError('process and on_close must be callable')
        if isinstance(capacity, bool) or not isinstance(capacity, int) or capacity < 1:
            raise ValueError('capacity must be a positive integer')
        if (isinstance(preview_capacity, bool) or not isinstance(preview_capacity, int)
                or preview_capacity < 1):
            raise ValueError('preview_capacity must be a positive integer')
        if not math.isfinite(lease_seconds) or lease_seconds <= 0:
            raise ValueError('lease_seconds must be positive')
        self._validate_mode(mode)
        self._process = process
        self._pipeline = pipeline
        self._on_result = on_result
        self._inflight_count = 0
        self._on_close = on_close
        self._capacity = capacity
        self._preview_capacity = preview_capacity
        self._lease_seconds = float(lease_seconds)
        self._condition = threading.Condition()
        # Serialize controls while pause waits, so a concurrent resume cannot
        # reopen dispatch before that pause has observed the transfer finish.
        self._controls = threading.Lock()
        self._pending = deque()
        self._results = deque(maxlen=preview_capacity)
        self._completed_times_ms = deque(maxlen=512)
        self._mode = mode
        self._paused = True
        self._busy = False
        self._stop_requested = False
        self._stopped = False
        self._error = None
        self._next_sequence = 0
        self._completed = 0
        self._dropped = 0
        self._started_at = self._last_contact = time.monotonic()
        self._thread = threading.Thread(target=self._run, name='queued-frame-stream', daemon=True)
        self._thread.start()

    @staticmethod
    def _validate_mode(mode):
        if isinstance(mode, bool) or not isinstance(mode, int) or mode not in range(5):
            raise ValueError('mode must be an integer in 0..4')

    def _expire_locked(self):
        if (not self._stop_requested and
                time.monotonic() - self._last_contact >= self._lease_seconds):
            self._request_stop_locked()

    def _touch_locked(self):
        # An already abandoned session cannot be revived by a late request.
        self._expire_locked()
        self._last_contact = time.monotonic()
        self._condition.notify_all()

    def _request_stop_locked(self):
        self._stop_requested = True
        self._paused = True
        self._pending.clear()
        self._condition.notify_all()

    def _snapshot_locked(self):
        cutoff = time.time() * 1000.0 - 10000.0
        while self._completed_times_ms and self._completed_times_ms[0] < cutoff:
            self._completed_times_ms.popleft()
        return {'paused': self._paused, 'busy': self._busy,
                'stopping': self._stop_requested, 'stopped': self._stopped,
                'error': self._error, 'pending': len(self._pending),
                'capacity': self._capacity, 'completed': self._completed,
                'inflight': self._inflight_count,
                'inflight_capacity': self._pipeline.capacity if self._pipeline is not None else 1,
                'dropped': self._dropped, 'mode': self._mode,
                'completed_times_ms': list(self._completed_times_ms)}

    def snapshot(self):
        with self._condition:
            self._touch_locked()
            return self._snapshot_locked()

    def enqueue(self, frame):
        """Accept one source without waiting for capacity or board progress.

        Sequences must start at zero and increase by one per accepted frame.
        A rejected full-queue request does not consume its sequence number.
        """
        with self._condition:
            self._touch_locked()
            if self._stop_requested or self._stopped:
                raise RuntimeError(self._error or 'stream session is stopping or stopped')
            if not isinstance(frame, dict):
                raise ValueError('frame must be a dictionary')
            sequence = frame.get('sequence')
            if (isinstance(sequence, bool) or not isinstance(sequence, int) or
                    sequence != self._next_sequence):
                raise ValueError('expected frame sequence %d' % self._next_sequence)
            data = frame.get('data')
            if not isinstance(data, (bytes, bytearray, memoryview)):
                raise ValueError('source frame must contain exactly 65536 bytes')
            data = bytes(data)
            if len(data) != FRAME_BYTES:
                raise ValueError('source frame must contain exactly 65536 bytes')
            if len(self._pending) >= self._capacity:
                raise QueueFull('stream source queue is full')
            source = dict(frame)
            source['data'] = data
            self._pending.append(source)
            self._next_sequence += 1
            self._condition.notify_all()
            return self._snapshot_locked()

    def control(self, action, mode=None):
        """Resume, pause, stop, or update the mode used by future dispatches.

        Pause waits for the current callback to finish. Stop clears pending
        inputs immediately and permits an in-flight callback to finish.
        """
        with self._controls, self._condition:
            self._touch_locked()
            if action not in ('resume', 'pause', 'stop', 'mode'):
                raise ValueError('unknown stream control action')
            if mode is not None:
                self._validate_mode(mode)
            elif action == 'mode':
                raise ValueError('mode is required')
            if mode is not None:
                self._mode = mode
            if action == 'stop':
                self._request_stop_locked()
            elif action == 'pause':
                self._paused = True
                self._condition.notify_all()
                while self._busy and not self._stopped:
                    self._condition.wait()
            elif self._stop_requested or self._stopped:
                raise RuntimeError(self._error or 'stream session is stopping or stopped')
            elif action == 'resume':
                self._paused = False
                self._condition.notify_all()
            return self._snapshot_locked()

    def take_result(self, timeout=1.0):
        """Return the oldest retained preview, or None after timeout/shutdown."""
        if timeout is not None and timeout < 0:
            raise ValueError('timeout must be nonnegative or None')
        with self._condition:
            self._touch_locked()
            deadline = None if timeout is None else time.monotonic() + timeout
            while not self._results:
                if self._stopped:
                    return None
                self._expire_locked()
                now = time.monotonic()
                if deadline is not None and now >= deadline:
                    return None
                remaining = None if deadline is None else deadline - now
                self._condition.wait(remaining)
            return self._results.popleft()

    def wait(self, timeout=None):
        """Wait for worker shutdown; return whether on_close has completed."""
        with self._condition:
            self._touch_locked()
        if threading.current_thread() is self._thread:
            raise RuntimeError('stream worker cannot join itself')
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def close(self, timeout=None):
        self.control('stop')
        return self.wait(timeout)

    def _run(self):
        try:
            if self._pipeline is not None:
                self._run_pipeline()
                return
            while True:
                with self._condition:
                    self._expire_locked()
                    while not self._stop_requested and (self._paused or not self._pending):
                        remaining = self._lease_seconds - (time.monotonic() - self._last_contact)
                        self._condition.wait(max(0.0, remaining))
                        self._expire_locked()
                    if self._stop_requested:
                        return
                    source = self._pending.popleft()
                    mode = self._mode
                    self._busy = True
                started = time.monotonic()
                result = self._process(source, mode)
                if not isinstance(result, dict):
                    raise TypeError('frame processor must return a dictionary')
                finished = time.monotonic()
                preview = dict(result)
                with self._condition:
                    self._completed += 1
                    completed_at = time.time()
                    self._completed_times_ms.append(completed_at * 1000.0)
                    preview.update(source=source, frame_ms=(finished - started) * 1000.0,
                                   elapsed=(finished - self._started_at) * 1000.0,
                                   completed=self._completed, completed_at=completed_at)
                    preview.setdefault('mode', mode)
                    if len(self._results) == self._preview_capacity:
                        self._dropped += 1
                    self._results.append(preview)
                    self._busy = False
                    self._condition.notify_all()

        except Exception as error:
            with self._condition:
                self._error = '%s: %s' % (type(error).__name__, error)
                self._request_stop_locked()
                self._busy = False
                self._condition.notify_all()
        finally:
            try:
                self._on_close()
            except Exception as error:
                with self._condition:
                    if self._error is None:
                        self._error = '%s: %s' % (type(error).__name__, error)
            finally:
                with self._condition:
                    self._busy = False
                    self._inflight_count = 0
                    self._stopped = True
                    self._condition.notify_all()

    def _run_pipeline(self):
        """Fill available in-flight capacity independently of completed replies.

        Pause/stop stop dispatch immediately, then drain every already dispatched
        frame before releasing controls or DDR ownership. Previews never gate IO.
        """
        inflight = deque()
        while True:
            with self._condition:
                self._expire_locked()
                can_submit = (not self._paused and not self._stop_requested and self._pending
                              and len(inflight) < self._pipeline.capacity)
                if can_submit:
                    source = self._pending.popleft()
                    mode = self._mode
                    self._busy = True
                elif not inflight:
                    self._busy = False
                    self._inflight_count = 0
                    self._condition.notify_all()
                    if self._stop_requested:
                        return
                    remaining = self._lease_seconds - (time.monotonic()-self._last_contact)
                    self._condition.wait(max(0.0, remaining))
                    continue
            if can_submit:
                started = time.monotonic()
                future = self._pipeline.submit(source, mode)
                inflight.append((source, mode, started, future))
                def wake(_future):
                    with self._condition:
                        self._condition.notify_all()
                future.add_done_callback(wake)
                with self._condition:
                    self._inflight_count = len(inflight)
                    self._condition.notify_all()
                continue
            source, mode, started, future = inflight[0]
            if not future.done():
                with self._condition:
                    if not future.done():
                        self._condition.wait(.1)
                continue
            result = future.result()
            finished = time.monotonic()
            if self._on_result is not None:
                self._on_result(source, result)
            preview = dict(result)
            inflight.popleft()
            with self._condition:
                self._completed += 1
                completed_at = time.time()
                self._completed_times_ms.append(completed_at*1000)
                preview.update(source=source, frame_ms=(finished-started)*1000,
                               elapsed=(finished-self._started_at)*1000,
                               completed=self._completed, completed_at=completed_at)
                preview.setdefault('mode', mode)
                if len(self._results) == self._preview_capacity:
                    self._dropped += 1
                self._results.append(preview)
                self._busy = bool(inflight)
                self._inflight_count = len(inflight)
                self._condition.notify_all()
