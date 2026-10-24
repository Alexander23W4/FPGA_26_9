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
    def test_medical_readback_formats_pixel_volume_and_unavailable(self):
        response = ''.join(line(name, 0) for name in gui.PL_REGISTERS)
        values = (12345, 4567, 1, 0, 98765, 12300, 0xffffffff, 0xffffffff)
        for (name, address), value in zip(gui.MEDICAL_REGISTERS.items(), values):
            response += line(name, value, address)
        with patch.object(gui, '_board_talk', return_value=response):
            result = gui._readback_regs()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['medical_volume_index'], dict(
            EDV_LA='123.45', ESV_LA='45.67', EDV_RA='0.01', ESV_RA='0.00',
            EDV_LV='987.65', ESV_LV='123.00', EDV_RV=None, ESV_RV=None))
        self.assertEqual(result['medical_raw']['EDV_RV'], 0xffffffff)
        self.assertEqual(result['medical_volume_unit'], 'px^3')
        self.assertNotIn('medical_volumes_ml', result)

    def test_medical_readback_checks_word_addresses(self):
        with self.assertRaises(ValueError):
            gui._parse_pl_registers(line('EDV_LV', 12345, 0x50), ('EDV_LV',))
        with self.assertRaises(ValueError):
            gui._parse_pl_registers(line('EDV_LV', 0x100000000, 0x14), ('EDV_LV',))

    def test_old_firmware_without_medical_results_still_reads_controls(self):
        response = ''.join(line(name, 0) for name in gui.PL_REGISTERS)
        with patch.object(gui, '_board_talk', return_value=response):
            result = gui._readback_regs()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['medical_raw'], {})
        self.assertEqual(result['medical_volume_index'], {})

    @unittest.skipUnless(shutil.which('node'), 'Node.js is needed to execute GUI handlers')
    def test_actual_gui_handlers_through_http_and_uart_bridge(self):
        values = dict(MODE=0, CMD_REG=1, VIDEO_MODE=0, STATUS=120,
                      DATA_REG=37, LESION=65536, MASK_TRANSP=45, HDMI_EN=1)
        writes = []
        def uart(payload, **kwargs):
            if payload == b'R':
                return ''.join(line(name, value) for name, value in values.items())
            name = {ord('V'): 'VIDEO_MODE', ord('P'): 'MASK_TRANSP', ord('H'): 'HDMI_EN'}[payload[0]]
            values[name] = payload[1]
            writes.append(payload)
            return line(name, payload[1])
        class QuietHandler(gui.NetworkHandler):
            state = None
            def log_message(self, *args):
                pass
        server = gui.NetworkServer(('127.0.0.1', 0), QuietHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def render(mode, state=None):
            values['VIDEO_MODE'] = 0 if int(mode)==5 else int(mode)
            return {'ok': True, 'results': [], 'log': 'configured'}
        try:
            root = Path(__file__).resolve().parents[2]
            with patch.object(gui, '_board_talk', side_effect=uart), \
                 patch.object(gui, '_do_render', side_effect=render):
                result = subprocess.run([shutil.which('node'),
                    str(root/'scripts/tests/gui_display_controls.js'), gui.__file__,
                    'http://127.0.0.1:%d' % server.server_port],
                    capture_output=True, text=True, encoding='utf-8', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('GUI_DISPLAY_HTTP_OK', result.stdout)
            self.assertEqual(writes, [b'P'+bytes([a]) for a in (0,45,100)] + [b'H\x00', b'H\x01'])
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
                                 (gui._set_mask_transparency, (-1, 101, 256)),
                                 (gui._set_hdmi_enable, (-1, 2, 256))):
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
                      DATA_REG=120, LESION=65536, MASK_TRANSP=45, HDMI_EN=0)
        response = ''.join(line(name, value) for name, value in values.items())
        with patch.object(gui, '_board_talk', return_value=response) as talk:
            result = gui._readback_regs()
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['lesion_pixels'], 65536)
            self.assertEqual(result['actual_threshold'], 120)
            self.assertEqual(result['mask_transparency'], 45)
            self.assertEqual(result['hdmi_enabled'], 0)
            talk.assert_called_once_with(b'R', wait=2.0)

    def test_missing_register_is_not_silently_shown_as_zero(self):
        response = ''.join(line(name, 0) for name in gui.PL_REGISTERS if name != 'MASK_TRANSP')
        with patch.object(gui, '_board_talk', return_value=response):
            self.assertFalse(gui._readback_regs()['ok'])

    def test_hdmi_command_and_verified_readback(self):
        for enabled in (0, 1):
            with patch.object(gui, '_board_talk', return_value=line('HDMI_EN', enabled)) as talk:
                self.assertEqual(gui._set_hdmi_enable(enabled)['hdmi_enabled'], enabled)
                talk.assert_called_once_with(b'H' + bytes([enabled]))
        for bad in (line('HDMI_EN', 0), line('HDMI_EN', 1, 0x10), 'RESULT: OK\r\n'):
            with patch.object(gui, '_board_talk', return_value=bad):
                self.assertFalse(gui._set_hdmi_enable(1)['ok'])


if __name__ == '__main__':
    unittest.main()
