"""Concurrent stream queue boundaries, without board, browser, or filesystem."""
import threading
import time
import unittest

from queued_stream import FRAME_BYTES, QueueFull, QueuedStream


def frame(sequence):
    return {'data': bytes([sequence % 256]) * FRAME_BYTES,
            'name': '%03d.bin' % sequence, 'path': 'case/%03d.bin' % sequence,
            'index': sequence, 'sequence': sequence}


class QueuedStreamTests(unittest.TestCase):
    def session(self, process, close=lambda: None, **kwargs):
        stream = QueuedStream(process, close, **kwargs)
        self.addCleanup(lambda: self.assertTrue(stream.close(2), 'worker did not close'))
        return stream

    def await_state(self, stream, predicate):
        # Wait on the worker's notifications rather than timing sleeps/polling.
        with stream._condition:
            self.assertTrue(stream._condition.wait_for(
                lambda: predicate(stream._snapshot_locked()), timeout=2),
                stream._snapshot_locked())

    def test_completed_previews_never_gate_the_next_board_transfer(self):
        first_started = threading.Event()
        release_first = threading.Event()
        self.addCleanup(release_first.set)
        calls = []

        def process(source, mode):
            calls.append((source['sequence'], mode))
            if source['sequence'] == 0:
                first_started.set()
                self.assertTrue(release_first.wait(2))
            return {'raw': b'rgba', 'mode': mode}

        stream = self.session(process)
        stream.enqueue(frame(0))
        stream.control('resume')
        self.assertTrue(first_started.wait(2))
        for sequence in range(1, 5):
            stream.enqueue(frame(sequence))
        self.assertEqual(stream.snapshot()['pending'], 4)
        with self.assertRaises(QueueFull):
            stream.enqueue(frame(5))
        release_first.set()
        self.await_state(stream, lambda state: state['completed'] == 5)
        # No take_result call was needed to complete all five transmissions.
        self.assertEqual(calls, [(sequence, 0) for sequence in range(5)])
        self.assertEqual(stream.snapshot()['dropped'], 3)
        self.assertEqual(len(stream.snapshot()['completed_times_ms']), 5)
        retained = [stream.take_result(0), stream.take_result(0)]
        self.assertEqual([item['source']['sequence'] for item in retained], [3, 4])
        self.assertEqual([item['completed'] for item in retained], [4, 5])
        self.assertEqual(retained[-1]['raw'], b'rgba')
        self.assertGreater(retained[-1]['completed_at'], 0)
        self.assertGreaterEqual(retained[-1]['elapsed'], retained[-1]['frame_ms'])
        self.assertIsNone(stream.take_result(0))
        # Failed full-queue requests do not consume sequence numbers.
        stream.enqueue(frame(5))
        self.await_state(stream, lambda state: state['completed'] == 6)

    def test_prefill_is_paused_and_validates_source_and_sequence(self):
        started = threading.Event()
        stream = self.session(lambda source, mode: started.set() or {'mode': 3})
        with self.assertRaises(ValueError):
            stream.enqueue(frame(1))
        invalid = frame(0)
        invalid['data'] = b'short'
        with self.assertRaises(ValueError):
            stream.enqueue(invalid)
        mutable = frame(0)
        mutable['data'] = bytearray(mutable['data'])
        stream.enqueue(mutable)
        mutable['data'][0] = 123
        self.assertFalse(started.is_set())
        self.assertEqual(stream.snapshot()['pending'], 1)
        with self.assertRaises(ValueError):
            stream.enqueue(frame(0))
        stream.control('resume')
        result = stream.take_result(2)
        self.assertIsNotNone(result)
        self.assertEqual(result['source']['data'][0], 0)
        self.assertEqual(result['mode'], 3)  # Actual callback mode wins.

    def test_pause_waits_for_inflight_and_queued_frames_use_new_mode(self):
        started = threading.Event()
        release = threading.Event()
        paused = threading.Event()
        self.addCleanup(release.set)
        calls = []

        def process(source, mode):
            calls.append((source['sequence'], mode))
            if source['sequence'] == 0:
                started.set()
                self.assertTrue(release.wait(2))
            return {'mode': mode}

        stream = self.session(process)
        stream.enqueue(frame(0))
        stream.enqueue(frame(1))
        stream.control('resume', mode=1)
        self.assertTrue(started.wait(2))

        def pause():
            stream.control('pause')
            paused.set()

        controller = threading.Thread(target=pause)
        controller.start()
        self.addCleanup(controller.join, 2)
        self.await_state(stream, lambda state: state['paused'])
        self.assertFalse(paused.is_set())
        release.set()
        self.assertTrue(paused.wait(2))
        self.assertEqual(calls, [(0, 1)])
        self.assertEqual(stream.snapshot()['pending'], 1)
        stream.control('mode', mode=4)
        stream.control('resume')
        self.await_state(stream, lambda state: state['completed'] == 2)
        self.assertEqual(calls, [(0, 1), (1, 4)])

    def test_mode_change_during_inflight_applies_at_next_dispatch(self):
        started = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)
        calls = []

        def process(source, mode):
            calls.append(mode)
            if source['sequence'] == 0:
                started.set()
                self.assertTrue(release.wait(2))
            return {'mode': mode}

        stream = self.session(process)
        stream.enqueue(frame(0))
        stream.enqueue(frame(1))
        stream.control('resume')
        self.assertTrue(started.wait(2))
        stream.control('mode', mode=2)
        release.set()
        self.await_state(stream, lambda state: state['completed'] == 2)
        self.assertEqual(calls, [0, 2])
        for bad in (-1, 5, '2', True):
            with self.subTest(mode=bad), self.assertRaises(ValueError):
                stream.control('mode', mode=bad)
        with self.assertRaises(ValueError):
            stream.control('mode')

    def test_stop_discards_pending_but_finishes_inflight_and_releases_once(self):
        started = threading.Event()
        release = threading.Event()
        close_started = threading.Event()
        release_close = threading.Event()
        self.addCleanup(release.set)
        self.addCleanup(release_close.set)
        closed = []
        calls = []

        def process(source, mode):
            calls.append(source['sequence'])
            started.set()
            self.assertTrue(release.wait(2))
            return {'raw': b'last'}

        def on_close():
            closed.append(True)
            close_started.set()
            self.assertTrue(release_close.wait(2))

        stream = self.session(process, on_close)
        stream.enqueue(frame(0))
        stream.enqueue(frame(1))
        stream.control('resume')
        self.assertTrue(started.wait(2))
        state = stream.control('stop')
        self.assertEqual(state['pending'], 0)
        self.assertTrue(state['busy'])
        self.assertFalse(state['stopped'])
        with self.assertRaises(RuntimeError):
            stream.enqueue(frame(2))
        release.set()
        self.assertTrue(close_started.wait(2))
        self.assertFalse(stream.snapshot()['stopped'])
        release_close.set()
        self.assertTrue(stream.wait(2))
        self.assertEqual(calls, [0])
        self.assertEqual(closed, [True])
        self.assertEqual(stream.take_result(0)['raw'], b'last')
        self.assertIsNone(stream.take_result(0))
        self.assertTrue(stream.snapshot()['stopped'])

    def test_callback_failure_discards_pending_and_releases_owner(self):
        closed = threading.Event()

        def process(source, mode):
            raise RuntimeError('board disconnected')

        stream = self.session(process, closed.set)
        stream.enqueue(frame(0))
        stream.enqueue(frame(1))
        stream.control('resume')
        self.assertTrue(closed.wait(2))
        self.assertTrue(stream.wait(2))
        state = stream.snapshot()
        self.assertTrue(state['stopped'])
        self.assertFalse(state['busy'])
        self.assertEqual(state['pending'], 0)
        self.assertEqual(state['completed'], 0)
        self.assertIn('board disconnected', state['error'])
        self.assertIsNone(stream.take_result(0))
        with self.assertRaises(RuntimeError):
            stream.control('resume')

    def test_abandoned_initially_paused_session_releases_owner(self):
        closed = threading.Event()
        called = threading.Event()
        stream = self.session(lambda source, mode: called.set() or {}, closed.set)
        stream.enqueue(frame(0))
        with stream._condition:
            stream._last_contact = time.monotonic()-31
            stream._condition.notify_all()
        # No API contacts while waiting: an abandoned prefill must expire too.
        self.assertTrue(closed.wait(2))
        self.assertTrue(stream.wait(2))
        self.assertFalse(called.is_set())
        self.assertTrue(stream.snapshot()['stopped'])
        self.assertEqual(stream.snapshot()['pending'], 0)

    def test_pause_waiter_is_released_when_the_inflight_transfer_fails(self):
        started = threading.Event()
        release = threading.Event()
        paused = threading.Event()
        self.addCleanup(release.set)

        def process(source, mode):
            started.set()
            self.assertTrue(release.wait(2))
            raise ConnectionError('lost board')

        stream = self.session(process)
        stream.enqueue(frame(0))
        stream.control('resume')
        self.assertTrue(started.wait(2))

        def pause():
            stream.control('pause')
            paused.set()

        controller = threading.Thread(target=pause)
        controller.start()
        self.addCleanup(controller.join, 2)
        self.await_state(stream, lambda state: state['paused'])
        self.assertFalse(paused.is_set())
        release.set()
        self.assertTrue(paused.wait(2))
        self.assertTrue(stream.wait(2))
        self.assertIn('lost board', stream.snapshot()['error'])

    def test_close_callback_failure_still_finishes_shutdown(self):
        def close():
            raise RuntimeError('owner cleanup failed')

        stream = self.session(lambda source, mode: {}, close)
        self.assertTrue(stream.close(2))
        self.assertTrue(stream.snapshot()['stopped'])
        self.assertIn('owner cleanup failed', stream.snapshot()['error'])


if __name__ == '__main__':
    unittest.main()
