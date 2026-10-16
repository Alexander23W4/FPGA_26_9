"""Actual GUI handler, HTTP API, TCP client and files, with only the board mocked."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
import monitor_network as gui
from frame_transfer import FrameTransferClient
from test_frame_transfer import INPUT, running_board
from test_display_registers import line


class GuiFrameTransferTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is needed to execute GUI handlers')
    def test_real_button_through_network_and_saved_files(self):
        class QuietHandler(gui.NetworkHandler):
            def log_message(self, *args):
                pass
        for mode in range(6):
            with self.subTest(mode=mode):
                self.run_button(mode, QuietHandler)

    def run_button(self, mode, handler):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            original = Path(folder)/'original.bin'
            original.write_bytes(INPUT)
            state = gui.web_common.WebState(str(original), False)
            handler.state = state
            def uart(payload, wait=1.5):
                if payload == b'R':
                    values = dict(MODE=0, CMD_REG=0, VIDEO_MODE=board.mode, STATUS=128,
                                  DATA_REG=128, LESION=123, MASK_TRANSP=45)
                    return ''.join(line(name, value) for name, value in values.items())
                self.assertEqual(payload[0:1], b'V')
                self.assertEqual(board.uploads, board.acks)
                self.assertEqual(len(state.processed_results), board.acks)
                board.mode = payload[1]
                board.events.append(('mode', board.mode))
                return line('VIDEO_MODE', board.mode)
            results = Path(folder)/'results'
            client = FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            client.folder = str(results)
            server = gui.NetworkServer(('127.0.0.1', 0), handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                with patch.object(gui, '_FRAME_CLIENT', client), patch.object(gui, '_DISPLAY_PENDING', None), \
                     patch.object(gui, '_board_talk_locked', side_effect=uart):
                    script = Path(__file__).resolve().parents[2] / 'scripts/tests/gui_frame_transfer.js'
                    result = subprocess.run([shutil.which('node'), str(script), gui.__file__,
                                             'http://127.0.0.1:%d' % server.server_port, str(mode)],
                                            capture_output=True, text=True, encoding='utf-8', timeout=20)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('GUI_FRAME_HTTP_OK', result.stdout)
                modes = list(range(5)) if mode == 5 else [mode]
                self.assertEqual((board.uploads, board.acks), (len(modes), len(modes)))
                self.assertEqual(board.events, [(event, m) for m in modes for event in ('mode', 'upload', 'ack')])
                self.assertEqual(len(list(results.glob('*.bin'))), len(modes))
                self.assertEqual(len(list(results.glob('*.png'))), len(modes))
                self.assertEqual(sorted(state.processed_results), [str(m) for m in modes])
                for m in modes:
                    raw = Path(state.processed_results[str(m)]['files']['bin']).read_bytes()
                    self.assertEqual(raw, bytes([11,22,33,m])*65536)
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)


if __name__ == '__main__':
    unittest.main()
