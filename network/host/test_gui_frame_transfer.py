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
    def test_real_selection_mode_and_threshold_events(self):
        class QuietHandler(gui.NetworkHandler):
            def log_message(self, *args):
                pass
        for mode in range(6):
            with self.subTest(mode=mode):
                self.run_button(mode, QuietHandler)

    def run_button(self, mode, handler):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            board.rgba = True
            original = Path(folder)/'original.bin'
            original.write_bytes(INPUT)
            state = gui.web_common.WebState(str(original), False)
            handler.state = state
            thresholds, opacities = [], []
            opacity = 45
            hdmi_enabled = 1
            hdmi_changes = []
            def uart(payload, wait=1.5):
                nonlocal opacity, hdmi_enabled
                if payload == b'R':
                    values = dict(MODE=0, CMD_REG=0, VIDEO_MODE=board.mode, STATUS=128,
                                  DATA_REG=128, LESION=123, MASK_TRANSP=opacity, HDMI_EN=hdmi_enabled)
                    return ''.join(line(name, value) for name, value in values.items())
                if payload[0:1] == b'P':
                    opacities.append(payload)
                    board.events.append(('opacity', payload[1]))
                    opacity = payload[1]
                    return line('MASK_TRANSP', opacity + int(len(opacities)>1))
                if payload[0:1] == b'H':
                    hdmi_enabled = payload[1]
                    hdmi_changes.append(hdmi_enabled)
                    board.events.append(('hdmi', hdmi_enabled))
                    return line('HDMI_EN', hdmi_enabled if len(hdmi_changes)<3 else 1-hdmi_enabled)
                self.assertEqual(payload[0:1], b'T')
                thresholds.append(payload)
                board.events.append(('threshold', payload[-1]))
                return line('CMD_REG', payload[1]) + line('DATA_REG', payload[-1] + int(len(thresholds)>1))
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
                self.assertEqual((board.uploads, board.acks), (4, 2*len(modes)+3))
                self.assertEqual(board.renders, 2*len(modes)-1)
                self.assertEqual(len(list(results.glob('*.bin'))), 2*len(modes)+3)
                self.assertEqual(len(list(results.glob('*.png'))), 2*len(modes)+3)
                self.assertEqual(hdmi_changes, [0,1,0])
                enabled_index = board.events.index(('hdmi', 1))
                self.assertEqual(board.events[enabled_index+1], ('upload', 3))
                opacity_index = board.events.index(('opacity', 35))
                self.assertEqual(board.events[opacity_index+1], ('upload', 4 if mode==5 else mode))
                threshold_index = board.events.index(('threshold', 77))
                self.assertEqual(board.events[threshold_index+1], ('upload', 3))
                self.assertEqual(sorted(state.processed_results), ['3'])
                for m in (3,):
                    raw = Path(state.processed_results[str(m)]['files']['bin']).read_bytes()
                    self.assertEqual(raw, bytes([33,22,11,255])*65536)
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)


if __name__ == '__main__':
    unittest.main()
