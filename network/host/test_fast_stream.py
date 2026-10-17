"""Real TCP/HTTP pipeline: receive ACK precedes PNG/save, bounded queues and metadata CRC."""
import contextlib
import json
import shutil
import subprocess
from pathlib import Path
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen

import frame_transfer as transfer
import monitor_network as gui
from test_frame_transfer import INPUT, running_board
from test_display_registers import line


@contextlib.contextmanager
def fast_server():
    class QuietHandler(gui.NetworkHandler):
        def log_message(self, *args):
            pass
    with running_board() as board, tempfile.TemporaryDirectory() as folder:
        initial = Path(folder, 'original.bin'); initial.write_bytes(INPUT)
        state = gui.web_common.WebState(str(initial), False)
        QuietHandler.state = state
        client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
        server = gui.NetworkServer(('127.0.0.1', 0), QuietHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        with patch.object(gui, '_FRAME_CLIENT', client), patch.object(gui, '_DISPLAY_PENDING', None):
            try:
                yield board, client, server, state, 'http://127.0.0.1:%d' % server.server_port
            finally:
                server.shutdown(); server.server_close(); worker.join(2); client.close()


def post_frame(base, name='001.bin', image=INPUT, mode=4):
    request = Request(base+'/api/network/frame?folder=CaseA&path='+name+'&name='+name+'&mode='+str(mode),
                      data=image, headers={'Content-Type': 'application/octet-stream'})
    with urlopen(request, timeout=5) as response:
        body = response.read()
    length = struct.unpack('!I', body[:4])[0]
    return json.loads(body[4:4+length]), body[4+length:]


class FastStreamTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is required')
    def test_real_gui_worker_does_not_wait_for_repaint(self):
        with fast_server() as (board, client, server, state, base):
            board.mode = 0
            def uart(payload, wait=1.5):
                if payload[:1] == b'T':
                    board.manual, board.threshold = payload[1:]
                    return line('CMD_REG', board.manual)+line('DATA_REG', board.threshold)
                if payload[:1] == b'P':
                    board.alpha = payload[1]
                    return line('MASK_TRANSP', board.alpha)
                raise AssertionError('unexpected per-frame UART command')
            with patch.object(gui, '_board_talk_locked', side_effect=uart):
                script = Path(gui.__file__).parents[2]/'scripts/tests/gui_fast_stream.js'
                run = subprocess.run([shutil.which('node'), str(script), gui.__file__, base],
                                     capture_output=True, text=True, encoding='utf-8', timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
            self.assertIn('FAST_GUI_OK', run.stdout)
            self.assertEqual((board.uploads, board.acks, board.connections), (3,4,1))
    def test_full_receive_releases_ddr_without_any_png_or_disk_work(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            try:
                with patch.object(transfer, 'save_result', side_effect=AssertionError('network must not save')):
                    result = client.receive_frame(INPUT)
                    again = client.receive_frame(INPUT)
                self.assertEqual(result['raw'], board.raw)
                self.assertEqual(result['readback']['lesion_pixels'], 1234)
                self.assertEqual(result['readback']['actual_threshold'], 128)
                self.assertNotEqual(result['job'], again['job'])
                self.assertEqual((board.uploads, board.acks, board.connections), (2, 2, 1))
                self.assertFalse(list(Path(folder).iterdir()))
            finally:
                client.close()

    def test_crc_or_metadata_failure_cannot_acknowledge(self):
        for bad in ('crc', 'metadata', 'pixel'):
            with self.subTest(bad=bad), running_board() as board, tempfile.TemporaryDirectory() as folder:
                client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
                if bad == 'crc': board.bad_crc = True
                if bad == 'metadata': board.alpha = 101
                if bad == 'pixel': board.raw_factory = lambda b, image: bytes([1,2,3,0])*65536
                try:
                    with self.assertRaises(ValueError): client.receive_frame(INPUT)
                    self.assertEqual(board.acks, 0)
                finally:
                    client.close()

    def test_lost_done_resumes_owned_bin_without_reuploading(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            board.lose_done = True
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            try:
                result = client.receive_frame(INPUT)
                self.assertEqual(result['raw'], board.raw)
                self.assertEqual((board.uploads, board.resumes, board.acks), (1,1,1))
            finally:
                client.close()

    def test_http_stream_never_encodes_png_or_saves_any_result(self):
        with fast_server() as (board, client, server, state, base):
            with patch.object(transfer, 'save_result', side_effect=AssertionError('stream cannot save')), \
                 patch.object(gui.web_common.Image.Image, 'save', side_effect=AssertionError('stream cannot encode PNG')), \
                 patch.object(gui, '_readback_regs', side_effect=AssertionError('no per-frame UART')):
                first, raw = post_frame(base)
                second, raw2 = post_frame(base, image=INPUT[::-1], mode=3)
                self.assertEqual((board.uploads, board.renders, board.acks, board.connections), (2,1,3,1))
                self.assertEqual(second['readback']['video_mode'], 3)
                self.assertEqual(raw2[3::4], bytes([3])*65536)
                self.assertNotIn('files', first)
                self.assertNotIn('files', second)
                with urlopen(base+'/api/network/state') as response: status=json.load(response)
                self.assertNotIn('image', status)
                self.assertNotIn('processed_results', status)
                self.assertLess(len(json.dumps(status)), 4096)
                self.assertEqual([p.name for p in Path(client.folder).iterdir()], ['original.bin'])


if __name__ == '__main__':
    unittest.main()
