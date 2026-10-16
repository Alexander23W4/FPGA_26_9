"""Folder streaming across real GUI handlers, HTTP, TCP and durable files."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from PIL import Image
import frame_transfer as transfer
import monitor_network as gui
from test_display_registers import line
from test_frame_transfer import INPUT, running_board


class StreamFolderTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is required for actual GUI handlers')
    def test_folder_loop_waits_for_new_result_and_applies_controls_between_frames(self):
        class QuietHandler(gui.NetworkHandler):
            def log_message(self, *args):
                pass

        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / 'original.bin'
            original.write_bytes(INPUT)
            state = gui.web_common.WebState(str(original), False)
            QuietHandler.state = state
            results = Path(folder) / 'results'
            (results / 'CaseA').mkdir(parents=True)
            stale = results / 'CaseA/001.bin'
            stale.write_bytes(b'stale incomplete result')
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], str(results), 2)
            board.mode = 0
            board.raw_factory = lambda b, image: bytes([10 + b.uploads, 20 + image[0], 30, b.mode]) * 65536
            received_files = []

            def check_saved():
                name = '001.bin' if board.input_images[-1][0] == 1 else '002.bin'
                binary = results / 'CaseA' / name
                self.assertEqual(binary.read_bytes(), board.raw, 'SAVED must acknowledge this new result')
                with Image.open(binary.with_suffix('.png')) as image:
                    self.assertEqual(image.getpixel((0, 0)), (board.raw[2], board.raw[1], board.raw[0]))
                received_files.append((board.job, binary, binary.read_bytes()))
            board.check_saved = check_saved
            threshold, opacity = 128, 45

            def uart(payload, wait=1.5):
                nonlocal threshold, opacity
                if payload == b'R':
                    board.events.append(('readback', board.acks))
                    values = dict(MODE=0, CMD_REG=1, VIDEO_MODE=board.mode, STATUS=threshold,
                                  DATA_REG=threshold, LESION=board.uploads * 100, MASK_TRANSP=opacity)
                    return ''.join(line(name, value) for name, value in values.items())
                if payload[:1] == b'T':
                    threshold = payload[-1]
                    board.events.append(('threshold', threshold))
                    return line('CMD_REG', payload[1]) + line('DATA_REG', threshold)
                if payload[:1] == b'P':
                    opacity = payload[1]
                    board.events.append(('opacity', opacity))
                    return line('MASK_TRANSP', opacity)
                self.fail('unexpected UART write: %r' % payload)

            server = gui.NetworkServer(('127.0.0.1', 0), QuietHandler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                with patch.object(gui, '_FRAME_CLIENT', client), patch.object(gui, '_DISPLAY_PENDING', None), \
                     patch.object(gui, '_board_talk_locked', side_effect=uart):
                    script = Path(__file__).resolve().parents[2] / 'scripts/tests/gui_stream_folder.js'
                    result = subprocess.run([shutil.which('node'), str(script), gui.__file__,
                                             'http://127.0.0.1:%d' % server.server_port],
                                            capture_output=True, text=True, encoding='utf-8', timeout=20)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('GUI_STREAM_HTTP_OK', result.stdout)
                self.assertEqual(board.input_images, [bytes([1]) * 65536, bytes([2]) * 65536, bytes([1]) * 65536])
                self.assertEqual((board.uploads, board.acks, board.renders), (3, 4, 1))
                self.assertEqual(len({job for job, _, _ in received_files}), 4)
                uploads = [i for i, (kind, _) in enumerate(board.events) if kind == 'upload']
                reads = [i for i, (kind, _) in enumerate(board.events) if kind == 'readback']
                self.assertEqual(len(reads), 3)
                self.assertEqual([value for kind, value in board.events if kind == 'readback'], [1, 3, 4],
                                 'readback must follow every completed result save/DONE')
                for index in range(2):
                    self.assertLess(uploads[index], reads[index])
                    self.assertLess(reads[index], uploads[index + 1])
                self.assertLess(reads[0], board.events.index(('threshold', 77)))
                self.assertLess(board.events.index(('opacity', 35)), uploads[1])
                self.assertEqual(stale.read_bytes(), bytes([13, 21, 30, 3]) * 65536)
                self.assertEqual(sorted(p.relative_to(results).as_posix() for p in results.rglob('*.bin')),
                                 ['CaseA/001.bin', 'CaseA/002.bin'])
                self.assertFalse(list(results.rglob('*.part')))
            finally:
                server.shutdown(); server.server_close(); worker.join(2)

    def test_stream_api_rejects_full_display_and_invalid_paths_without_upload(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / 'original.bin'; original.write_bytes(INPUT)
            state = gui.web_common.WebState(str(original), False)
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            with patch.object(gui, '_FRAME_CLIENT', client), patch.object(gui, '_DISPLAY_PENDING', None):
                for mode, stream_path in [(5, '001.bin'), (0, '../outside.bin'), (0, 'different.bin')]:
                    with self.subTest(mode=mode, path=stream_path):
                        result = gui._do_transfer(INPUT, filename='001.bin', mode=mode, state=state,
                                                  stream_folder='CaseA', stream_path=stream_path)
                        self.assertFalse(result['ok'])
                self.assertEqual(board.uploads, 0)

    @unittest.skipUnless(shutil.which('node'), 'Node.js is required for actual GUI handlers')
    def test_failed_return_stops_loop_and_never_loads_stale_output(self):
        class QuietHandler(gui.NetworkHandler):
            def log_message(self, *args):
                pass
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            original = Path(folder) / 'original.bin'; original.write_bytes(INPUT)
            state = gui.web_common.WebState(str(original), False)
            QuietHandler.state = state
            results = Path(folder) / 'results'
            (results / 'CaseA').mkdir(parents=True)
            stale = results / 'CaseA/001.bin'; stale.write_bytes(b'old confirmed result')
            board.mode = 0; board.bad_crc = True
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], str(results), 2)
            server = gui.NetworkServer(('127.0.0.1', 0), QuietHandler)
            worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
            try:
                with patch.object(gui, '_FRAME_CLIENT', client), patch.object(gui, '_DISPLAY_PENDING', None):
                    script = Path(__file__).resolve().parents[2] / 'scripts/tests/gui_stream_folder.js'
                    result = subprocess.run([shutil.which('node'), str(script), gui.__file__,
                                             'http://127.0.0.1:%d' % server.server_port, 'failure'],
                                            capture_output=True, text=True, encoding='utf-8', timeout=20)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('GUI_STREAM_FAILURE_OK', result.stdout)
                self.assertEqual((board.uploads, board.acks, board.renders), (1, 0, 0))
                self.assertEqual(stale.read_bytes(), b'old confirmed result')
                self.assertEqual(board.input_images, [bytes([1]) * 65536])
            finally:
                server.shutdown(); server.server_close(); worker.join(2)


if __name__ == '__main__':
    unittest.main()
