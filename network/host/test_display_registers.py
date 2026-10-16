"""Offline checks of the GUI -> UART register protocol, with no board access."""
import unittest
import shutil
import subprocess
import threading
from pathlib import Path
from unittest.mock import patch
import monitor_network as gui


def line(name, value, address=None):
    if address is None:
        address = gui.PL_REGISTERS[name]
    return '[PL rdbk] %s(0x%02X) = %d\r\n' % (name, address, value)


class DisplayRegistersTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node.js is needed to execute GUI handlers')
    def test_actual_gui_handlers_through_http_and_uart_bridge(self):
        values = dict(MODE=0, CMD_REG=1, VIDEO_MODE=0, STATUS=120,
                      DATA_REG=120, LESION=65536, MASK_TRANSP=45)
        writes = []
        def uart(payload, **kwargs):
            if payload == b'R':
                return ''.join(line(name, value) for name, value in values.items())
            name = {ord('V'): 'VIDEO_MODE', ord('P'): 'MASK_TRANSP'}[payload[0]]
            values[name] = payload[1]
            writes.append(payload)
            return line(name, payload[1])
        class QuietHandler(gui.NetworkHandler):
            def log_message(self, *args):
                pass
        server = gui.NetworkServer(('127.0.0.1', 0), QuietHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            root = Path(__file__).resolve().parents[2]
            with patch.object(gui, '_board_talk', side_effect=uart):
                result = subprocess.run([shutil.which('node'),
                    str(root/'scripts/tests/gui_display_controls.js'), gui.__file__,
                    'http://127.0.0.1:%d' % server.server_port],
                    capture_output=True, text=True, encoding='utf-8', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('GUI_DISPLAY_HTTP_OK', result.stdout)
            self.assertEqual(writes, [b'V'+bytes([m]) for m in (3,4,2,0,1)] +
                                     [b'P'+bytes([a]) for a in (0,45,100)])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(2)

    def test_all_five_video_modes_send_and_verify_the_byte(self):
        for mode in range(5):
            with self.subTest(mode=mode), patch.object(gui, '_board_talk', return_value=line('VIDEO_MODE', mode)) as talk:
                result = gui._set_video_mode(mode)
                self.assertTrue(result['ok'], result)
                self.assertEqual(result['video_mode'], mode)
                talk.assert_called_once_with(b'V' + bytes([mode]))

    def test_opacity_endpoints_and_default(self):
        for value in (0, 45, 100):
            with self.subTest(value=value), patch.object(gui, '_board_talk', return_value=line('MASK_TRANSP', value)) as talk:
                result = gui._set_mask_transparency(value)
                self.assertTrue(result['ok'], result)
                self.assertEqual(result['mask_transparency'], value)
                talk.assert_called_once_with(b'P' + bytes([value]))

    def test_invalid_values_never_touch_uart(self):
        for function, values in ((gui._set_video_mode, (-1, 5, 256)),
                                 (gui._set_mask_transparency, (-1, 101, 256))):
            for value in values:
                with self.subTest(value=value), patch.object(gui, '_board_talk') as talk:
                    self.assertFalse(function(value)['ok'])
                    talk.assert_not_called()

    def test_mismatched_readback_and_old_firmware_are_failures(self):
        for response in (line('VIDEO_MODE', 0), line('VIDEO_MODE', 4, 0x10),
                         'RESULT: OK\r\n'):
            with self.subTest(response=response), patch.object(gui, '_board_talk', return_value=response):
                self.assertFalse(gui._set_video_mode(4)['ok'])

    def test_full_readback_preserves_17_bit_area_and_new_fields(self):
        values = dict(MODE=0, CMD_REG=1, VIDEO_MODE=3, STATUS=120,
                      DATA_REG=120, LESION=65536, MASK_TRANSP=45)
        response = ''.join(line(name, value) for name, value in values.items())
        with patch.object(gui, '_board_talk', return_value=response) as talk:
            result = gui._readback_regs()
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['lesion_pixels'], 65536)
            self.assertEqual(result['actual_threshold'], 120)
            self.assertEqual(result['mask_transparency'], 45)
            talk.assert_called_once_with(b'R', wait=2.0)

    def test_missing_register_is_not_silently_shown_as_zero(self):
        response = ''.join(line(name, 0) for name in gui.PL_REGISTERS if name != 'MASK_TRANSP')
        with patch.object(gui, '_board_talk', return_value=response):
            self.assertFalse(gui._readback_regs()['ok'])


if __name__ == '__main__':
    unittest.main()
