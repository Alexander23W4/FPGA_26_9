"""Backend stream completion and recoverable failure boundaries, without a board."""
from pathlib import Path
import json
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import frame_transfer as transfer
import monitor_network as gui
from test_display_transfer import display_board
from test_frame_transfer import INPUT


class StreamBackendTests(unittest.TestCase):
    def send(self, data, state, path='001.bin', folder='CaseA'):
        return gui._do_transfer(data, filename=Path(path).name, mode=4, state=state,
                                stream_folder=folder, stream_path=path)

    def test_identical_stream_frame_still_uploads_and_reads_registers_again(self):
        with display_board() as (board, state, client):
            def readback():
                board.events.append(('readback', board.acks))
                return {'ok': True, 'frame': board.uploads}
            with patch.object(gui, '_readback_regs', side_effect=readback):
                first = self.send(INPUT, state)
                second = self.send(INPUT, state)
            self.assertTrue(first['ok'], first)
            self.assertTrue(second['ok'], second)
            self.assertEqual((board.uploads, board.acks), (2, 2))
            self.assertEqual(first['files'], second['files'])
            self.assertNotEqual(first['results'][0]['job'], second['results'][0]['job'])
            self.assertEqual(second['readback']['frame'], 2)
            self.assertEqual([event for event in board.events if event[0] in ('upload', 'ack', 'readback')],
                             [('upload', 4), ('ack', 4), ('readback', 1),
                              ('upload', 4), ('ack', 4), ('readback', 2)])
            self.assertGreater(second['results_revision'], first['results_revision'])

    def test_readback_failure_keeps_frame_pending_until_same_frame_retry(self):
        with display_board() as (board, state, client):
            with patch.object(gui, '_readback_regs', return_value={'ok': False, 'log': 'R failed'}):
                failed = self.send(INPUT, state)
            self.assertFalse(failed['ok'])
            self.assertEqual((board.uploads, board.acks), (1, 1))
            self.assertIsNone(client.pending)
            self.assertIsNotNone(gui._DISPLAY_PENDING)
            self.assertFalse(self.send(INPUT[::-1], state, '002.bin')['ok'])
            self.assertEqual((board.uploads, board.acks), (1, 1))
            with patch.object(gui, '_readback_regs', return_value={'ok': True, 'frame': 1}):
                recovered = self.send(INPUT, state)
            self.assertTrue(recovered['ok'], recovered)
            self.assertEqual((board.uploads, board.acks, board.resumes), (1, 1, 0))
            self.assertIsNone(gui._DISPLAY_PENDING)
            self.assertEqual(recovered['results'][0]['job'], failed['results'][0]['job'])

    def test_save_failure_retries_original_path_without_publishing_disk_cache(self):
        with display_board() as (board, state, client):
            binary = Path(client.folder, 'CaseA', '001.bin')
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'previous output')
            with patch.object(transfer, 'save_result', side_effect=PermissionError('disk full')):
                failed = self.send(INPUT, state)
            self.assertFalse(failed['ok'])
            self.assertEqual(binary.read_bytes(), b'previous output')
            self.assertFalse(state.processed_results)
            before = state.source_revision
            wrong_path = self.send(INPUT, state, folder='OtherFolder')
            self.assertFalse(wrong_path['ok'])
            self.assertEqual(state.source_revision, before)
            self.assertEqual((board.uploads, board.acks), (1, 0))
            with patch.object(gui, '_readback_regs', return_value={'ok': True}):
                recovered = self.send(INPUT, state)
            self.assertTrue(recovered['ok'], recovered)
            self.assertEqual((board.uploads, board.resumes, board.acks), (1, 1, 1))
            self.assertEqual(binary.read_bytes(), board.raw)
            self.assertEqual(state.processed_results['4']['job'], recovered['results'][0]['job'])

    def test_preview_preflight_rejects_pending_folder_path_and_source_kind_changes(self):
        class QuietHandler(gui.NetworkHandler):
            def log_message(self, *args):
                pass

        with display_board() as (board, state, client):
            with patch.object(gui, '_readback_regs', return_value={'ok': False, 'log': 'R failed'}):
                failed = self.send(INPUT, state, path='sub/001.bin')
            self.assertFalse(failed['ok'])
            self.assertIsNotNone(gui._DISPLAY_PENDING)
            QuietHandler.state = state
            server = gui.NetworkServer(('127.0.0.1', 0), QuietHandler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            before = state.source_revision
            try:
                for query in (
                        'stream=1&folder=OtherFolder&path=sub/001.bin',
                        'stream=1&folder=CaseA&path=other/001.bin',
                        'stream=0'):
                    request = Request('http://127.0.0.1:%d/api/image?name=001.bin&%s' %
                                      (server.server_port, query), data=INPUT, method='POST')
                    with self.subTest(query=query), self.assertRaises(HTTPError) as error:
                        urlopen(request, timeout=2)
                    self.assertEqual(error.exception.code, 400)
                    error.exception.close()
                    self.assertEqual(state.source_revision, before)
                    self.assertEqual(state.stream_folder, 'CaseA')
                request = Request('http://127.0.0.1:%d/api/image?name=001.bin&'
                                  'stream=1&folder=CaseA&path=sub/001.bin' % server.server_port,
                                  data=INPUT, method='POST')
                with urlopen(request, timeout=2) as response:
                    restored = json.load(response)
                self.assertTrue(restored['ok'], restored)
                self.assertEqual(state.source_revision, before + 1)
                self.assertEqual((board.uploads, board.acks), (1, 1))
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)


if __name__ == '__main__':
    unittest.main()
