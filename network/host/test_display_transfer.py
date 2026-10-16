"""Batch ordering, partial failure recovery and disk-backed GUI results."""
import base64
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image

import frame_transfer as transfer
import monitor_network as gui
from test_display_registers import line
from test_frame_transfer import INPUT, running_board


@contextlib.contextmanager
def display_board():
    with running_board() as board, tempfile.TemporaryDirectory() as folder:
        original = Path(folder)/'input.bin'
        original.write_bytes(INPUT)
        state = gui.web_common.WebState(str(original), False)
        client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1],
                                              str(Path(folder)/'results'), 2)
        def uart(payload, wait=1.5):
            assert payload[:1] == b'V'
            board.mode = payload[1]
            board.events.append(('mode', board.mode))
            return line('VIDEO_MODE', board.mode)
        with patch.object(gui, '_FRAME_CLIENT', client), patch.object(gui, '_DISPLAY_PENDING', None), \
             patch.object(gui, '_board_talk_locked', side_effect=uart):
            yield board, state, client


class DisplayTransferTests(unittest.TestCase):
    def test_partial_batch_retries_current_mode_without_repeating_completed_modes(self):
        with display_board() as (board, state, client):
            save = transfer.save_result
            def disk_failure(raw, filename, mode, job, folder):
                if mode == 2:
                    raise PermissionError('disk full')
                return save(raw, filename, mode, job, folder)
            with patch.object(transfer, 'save_result', side_effect=disk_failure):
                result = gui._do_transfer(INPUT, filename='input.bin', mode=5, state=state)
            self.assertFalse(result['ok'])
            self.assertEqual((board.uploads, board.acks), (3, 2))
            self.assertEqual(sorted(state.processed_results), ['0', '1'])
            self.assertFalse(state.transfer_status['busy'])
            self.assertIsNotNone(client.pending)
            self.assertFalse(gui._do_transfer(INPUT, filename='input.bin', mode=4)['ok'])
            self.assertFalse(gui._do_transfer(INPUT[::-1], filename='input.bin', mode=5)['ok'])
            self.assertEqual((board.uploads, board.acks), (3, 2))
            result = gui._do_transfer(INPUT, filename='input.bin', mode=5, state=state)
            self.assertTrue(result['ok'], result['log'])
            self.assertEqual((board.uploads, board.acks, board.resumes), (5, 5, 1))
            self.assertEqual([m for event, m in board.events if event == 'mode'], list(range(5)))
            self.assertEqual([item['mode'] for item in result['results']], list(range(5)))
            self.assertEqual(sorted(state.processed_results), ['0', '1', '2', '3', '4'])
            self.assertIsNone(gui._DISPLAY_PENDING)
            self.assertIsNone(client.pending)

    def test_mode_readback_failure_stops_before_upload(self):
        with display_board() as (board, state, client), \
             patch.object(gui, '_board_talk_locked', return_value=line('VIDEO_MODE', 0)):
            result = gui._do_transfer(INPUT, filename='input.bin', mode=3, state=state)
            self.assertFalse(result['ok'])
            self.assertIn('readback mismatch', result['log'])
            self.assertEqual((board.uploads, board.acks), (0, 0))
            self.assertFalse(state.processed_results)
            self.assertIsNone(client.pending)

    def test_original_and_processed_preview_use_exact_input_and_saved_bin(self):
        with display_board() as (board, state, client):
            result = gui._do_transfer(INPUT, filename='input.bin', mode=4, state=state)
            self.assertTrue(result['ok'], result['log'])
            # Processing preview must ignore local simulated overlay/window controls.
            state.mask = gui.np.ones((256, 256), dtype=gui.np.uint8)
            snapshot = state.snapshot(3, 1, 1, 100)
            with Image.open(io.BytesIO(base64.b64decode(snapshot['image']))) as original:
                self.assertEqual(original.tobytes(), INPUT)
            processed = snapshot['processed_results']['4']
            raw = Path(processed['files']['bin']).read_bytes()
            self.assertEqual(raw, board.raw)
            with Image.open(io.BytesIO(base64.b64decode(processed['image']))) as image:
                self.assertEqual(image.size, (256, 256))
                self.assertEqual(image.getpixel((0, 0)), (raw[2], raw[1], raw[0]))
            state.replace_image(INPUT[::-1], 'new.bin')
            self.assertFalse(state.processed_results)

    def test_invalid_display_mode_never_writes_or_uploads(self):
        with display_board() as (board, state, client):
            for mode in (-1, 6, 'invalid'):
                self.assertFalse(gui._do_transfer(INPUT, mode=mode, state=state)['ok'])
            self.assertFalse(board.events)


if __name__ == '__main__':
    unittest.main()
