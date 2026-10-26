"""HTTP/TCP checks for a bounded Python-owned input queue and independent previews."""
import contextlib
import json
from pathlib import Path
import struct
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import frame_transfer as transfer
import monitor_network as gui
from test_fast_stream import fast_server, post_frame
from test_frame_transfer import INPUT


PREFIX = '/api/network/stream/'


def request(base, endpoint, value=None, *, query=None, body=None):
    url = base + PREFIX + endpoint
    if query:
        url += '?' + urlencode(query)
    headers = {}
    if value is not None:
        body = json.dumps(value).encode()
        headers['Content-Type'] = 'application/json'
    elif body is not None:
        headers['Content-Type'] = 'application/octet-stream'
    try:
        response = urlopen(Request(url, data=body, headers=headers), timeout=5)
    except HTTPError as error:
        response = error
    with response:
        payload = response.read()
        kind = response.headers.get_content_type()
        status = response.status if hasattr(response, 'status') else response.code
    if not payload:
        return status, None, b''
    if kind == 'application/json':
        return status, json.loads(payload), b''
    size = struct.unpack('!I', payload[:4])[0]
    return status, json.loads(payload[4:4+size]), payload[4+size:]


def wait_for(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.01)
    return bool(predicate())


@contextlib.contextmanager
def queued_server(mode=4):
    with fast_server() as values:
        board, client, server, state, base = values
        board.mode = mode
        status, started, _ = request(base, 'start', {'folder': 'CaseA', 'mode': mode})
        if status != 200 or not started.get('ok'):
            raise AssertionError((status, started))
        token = started['session']
        try:
            yield (*values, token, started)
        finally:
            board.release_late.set()
            request(base, 'control', {'session': token, 'action': 'stop'})
            # Session stop is asynchronous so an in-flight board return can drain.
            wait_for(lambda: not gui._TRANSFER_LOCK.locked())


def enqueue(base, token, sequence, *, data=INPUT, index=None, path=None, name=None):
    name = name or '%03d.bin' % (sequence + 1)
    return request(base, 'enqueue', query={
        'session': token, 'name': name, 'path': path or 'sub/' + name,
        'index': sequence if index is None else index, 'sequence': sequence,
    }, body=data)


class QueuedStreamHTTPTests(unittest.TestCase):
    def test_medical_stop_has_only_one_dispatched_inference(self):
        with fast_server() as (board,client,server,state,base):
            state.system_mode='medical';board.stall_next=True
            _,started,_=request(base,'start',{'folder':'Patient','mode':1})
            token=started['session']
            try:
                self.assertEqual(server.stream._pipeline.capacity,1)
                self.assertEqual(server.stream._pipeline.timeout,300)
                for n in range(4):self.assertEqual(enqueue(base,token,n)[0],200)
                request(base,'control',{'session':token,'action':'resume'})
                self.assertTrue(wait_for(lambda:board.uploads==1))
                _,stopping,_=request(base,'control',{'session':token,'action':'stop'})
                self.assertEqual(stopping['pending'],0)
                self.assertEqual(board.uploads,1)
                board.release_late.set()
                self.assertTrue(server.stream.wait(3))
                self.assertEqual(board.uploads,1)
            finally:
                board.release_late.set();server.stream.close(3)

    def test_python_sends_prefetched_frames_without_gui_consuming_results_or_disk_work(self):
        with queued_server() as (board, client, server, state, base, token, started):
            self.assertEqual(started['capacity'], 4)
            images = [bytes([value])*65536 for value in (1, 2, 3)]
            with patch.object(transfer, 'save_result', side_effect=AssertionError('queued stream must not save')), \
                 patch.object(gui.web_common.Image.Image, 'save', side_effect=AssertionError('queued stream must not encode PNG')):
                for sequence, image in enumerate(images):
                    self.assertEqual(enqueue(base, token, sequence, data=image)[0], 200)
                self.assertEqual(board.uploads, 0, 'start must remain paused while initial frames are buffered')
                self.assertEqual(request(base, 'control', {'session': token, 'action': 'resume'})[0], 200)
                self.assertTrue(wait_for(lambda: board.uploads == 3 and board.sent == 3),
                                'Python must advance without any browser result request')
            self.assertEqual(board.input_images, images)
            self.assertEqual((board.connections, board.acks), (1, 0))
            self.assertEqual([p.name for p in Path(client.folder).iterdir()], ['original.bin'])
            with urlopen(base + '/api/network/state', timeout=5) as response:
                snapshot = json.load(response)
            text = json.dumps(snapshot)
            self.assertNotIn('processed_results', snapshot)
            self.assertNotIn('image', snapshot)
            self.assertLess(len(text), 8192, 'state polling must not copy queued images')
            request(base, 'control', {'session': token, 'action': 'stop'})
            previews = []
            for _ in range(8):
                status, metadata, raw = request(base, 'result', query={'session': token})
                if status == 204:
                    continue
                self.assertEqual(status, 200, metadata)
                if not raw:
                    self.assertTrue(metadata.get('stopped') or metadata.get('stream', {}).get('stopped'))
                    break
                self.assertEqual(len(raw), 65536 + 262144)
                stream = metadata['stream']
                self.assertEqual(raw[:65536], images[stream['sequence']])
                self.assertEqual(raw[65536+3::4], bytes([255])*65536)
                for key in ('index', 'sequence', 'completed', 'frame_ms', 'pending', 'capacity',
                            'paused', 'stopped', 'error', 'dropped'):
                    self.assertIn(key, stream)
                previews.append(stream['sequence'])
            else:
                self.fail('stopped session did not finish draining its bounded previews')
            self.assertTrue(previews)
            self.assertEqual(previews[-1], 2, 'bounded previews must retain the newest completed frame')
            self.assertLessEqual(len(previews), started['capacity'])

    def test_stop_discards_waiting_inputs_and_drains_all_dispatched_frames(self):
        with queued_server() as (board, client, server, state, base, token, started):
            board.stall_next = True
            board.pipeline_min_before_return = 4
            for sequence in range(4):
                self.assertEqual(enqueue(base, token, sequence)[0], 200)
            request(base, 'control', {'session': token, 'action': 'resume'})
            for sequence in range(4, 8):
                self.assertTrue(wait_for(lambda: gui._TRANSFER_LOCK.locked() and server.stream.snapshot()['pending'] < 4))
                self.assertEqual(enqueue(base, token, sequence)[0], 200)
            self.assertTrue(board.pipeline_received.wait(2))
            for sequence in range(8, 12):
                self.assertEqual(enqueue(base, token, sequence)[0], 200)
            self.assertEqual(board.uploads,4,'only four granted input slots may be sent while DMA is stalled')
            status, stopped, _ = request(base, 'control', {'session': token, 'action': 'stop'})
            self.assertEqual(status, 200, stopped)
            board.release_late.set()
            self.assertTrue(wait_for(lambda: not gui._TRANSFER_LOCK.locked()))
            self.assertEqual(board.uploads, 8, 'stop must discard pending inputs and drain eight already dispatched frames')
            metadata, raw = post_frame(base, name='fresh.bin')
            self.assertTrue(metadata['ok'])
            self.assertEqual(len(raw), 262144)
            self.assertEqual(board.uploads, 9)

    def test_full_queue_and_bad_sequence_are_recoverable(self):
        with queued_server() as (board, client, server, state, base, token, started):
            self.assertEqual(enqueue(base, token, 0)[0], 200)
            self.assertIn(enqueue(base, token, 2)[0], (400, 409),
                          'a sequence gap must be rejected even while there is free queue space')
            for sequence in range(1, started['capacity']):
                self.assertEqual(enqueue(base, token, sequence)[0], 200)
            self.assertEqual(enqueue(base, token, started['capacity'])[0], 409)
            self.assertIn(enqueue(base, token, 1)[0], (400, 409))
            self.assertEqual(board.uploads, 0)
            request(base, 'control', {'session': token, 'action': 'resume'})
            self.assertTrue(wait_for(lambda: board.uploads == started['capacity']))
            self.assertEqual(enqueue(base, token, started['capacity'])[0], 200,
                             'rejected requests must not consume the expected sequence number')
            self.assertTrue(wait_for(lambda: board.uploads == started['capacity'] + 1))

    def test_invalid_requests_cannot_start_board_work_or_poison_next_valid_input(self):
        with queued_server() as (board, client, server, state, base, token, started):
            for invalid in (
                {'token': 'unknown', 'sequence': 0},
                {'token': token, 'sequence': 0, 'path': '../outside.bin'},
                {'token': token, 'sequence': 0, 'data': INPUT[:-1]},
                {'token': token, 'sequence': -1},
            ):
                status, metadata, _ = enqueue(base, **invalid)
                self.assertGreaterEqual(status, 400, metadata)
            for value in (
                {'session': 'unknown', 'action': 'resume'},
                {'session': token, 'action': 'mode', 'mode': 5},
                {'session': token, 'action': 'unknown'},
            ):
                status, metadata, _ = request(base, 'control', value)
                self.assertGreaterEqual(status, 400, metadata)
            self.assertEqual(board.uploads, 0)
            self.assertEqual(enqueue(base, token, 0)[0], 200)
            request(base, 'control', {'session': token, 'action': 'resume'})
            self.assertTrue(wait_for(lambda: board.uploads == 1 and board.sent == 1))


if __name__ == '__main__':
    unittest.main()
