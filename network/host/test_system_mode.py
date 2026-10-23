"""GUI -> HTTP -> PS M command -> verified MODE register, without a board."""
import json
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import monitor_network as gui
from test_fast_stream import fast_server
from test_display_registers import line


class SystemModeTests(unittest.TestCase):
    def test_mode_byte_and_readback_validation(self):
        for value in (0, 1):
            with patch.object(gui, '_board_talk', return_value=line('MODE', value)) as talk:
                self.assertEqual(gui._set_system_mode(value)['reg_mode'], value)
                talk.assert_called_once_with(b'M' + bytes([value]))
        for value in (-1, 2, 256):
            with patch.object(gui, '_board_talk') as talk:
                self.assertFalse(gui._set_system_mode(value)['ok'])
                talk.assert_not_called()
        for response in (line('MODE', 0), 'RESULT: OK\r\n'):
            with patch.object(gui, '_board_talk', return_value=response):
                self.assertFalse(gui._set_system_mode(1)['ok'])

    def test_http_and_state_commit_after_verified_write(self):
        with fast_server() as (_, _, _, state, base):
            writes = []
            def uart(payload, **_kwargs):
                writes.append(payload)
                return line('MODE', payload[1])
            with patch.object(gui, '_board_talk', side_effect=uart):
                for mode, value in (('medical', 1), ('processing', 0), ('simulation', None)):
                    with urlopen(base + '/api/system_mode?mode=' + mode) as response:
                        result = json.load(response)
                    self.assertTrue(result['ok'])
                    self.assertEqual(result['system_mode'], mode)
                    self.assertEqual(state.system_mode, mode)
                    self.assertEqual(state.simulate, mode == 'simulation')
                    if value is not None:
                        self.assertEqual(result['reg_mode'], value)
                self.assertEqual(writes, [b'M\x01', b'M\x00'])

    def test_busy_transfer_rejects_switch_without_writing_register(self):
        with fast_server() as (_, _, _, state, base):
            gui._TRANSFER_LOCK.acquire()
            try:
                with patch.object(gui, '_board_talk') as talk:
                    with self.assertRaises(HTTPError) as caught:
                        urlopen(base + '/api/system_mode?mode=medical')
                    self.assertEqual(caught.exception.code, 409)
                    caught.exception.close()
                    talk.assert_not_called()
                    self.assertEqual(state.system_mode, 'processing')
            finally:
                gui._TRANSFER_LOCK.release()

    def test_unconnected_medical_output_never_starts_return_wait(self):
        with fast_server() as (board, client, server, state, base):
            state.system_mode = 'medical'
            with patch.object(client, 'transfer') as transfer:
                result = gui._do_transfer(bytes(65536), state=state)
                self.assertFalse(result['ok'])
                self.assertIn('尚未连接', result['log'])
                transfer.assert_not_called()
            with self.assertRaisesRegex(RuntimeError, '尚未连接'):
                server.start_stream(state, {'folder': 'patient0001', 'mode': 0})
            request = Request(base + '/api/network/frame?folder=patient0001&path=001.bin&name=001.bin&mode=0',
                              data=bytes(65536))
            with self.assertRaises(HTTPError) as caught:
                urlopen(request)
            self.assertEqual(caught.exception.code, 400)
            caught.exception.close()
            self.assertEqual(board.uploads, 0)

    @unittest.skipUnless(shutil.which('node'), 'Node.js is required')
    def test_actual_gui_selects_medical_and_rolls_back_failed_write(self):
        with fast_server() as (_, _, _, state, base):
            writes = []
            def uart(payload, **_kwargs):
                writes.append(payload)
                return line('MODE', 0 if len(writes) == 3 else payload[1])
            root = Path(gui.__file__).parents[2]
            with patch.object(gui, '_board_talk', side_effect=uart):
                run = subprocess.run([shutil.which('node'), str(root/'scripts/tests/gui_system_mode.js'),
                                      str(root/'network/host/assets/heartcare.js'), base],
                                     capture_output=True, encoding='utf-8', timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('GUI_SYSTEM_MODE_OK', run.stdout)
            self.assertEqual(writes, [b'M\x01', b'M\x00', b'M\x01'])
            self.assertEqual(state.system_mode, 'processing')


if __name__ == '__main__':
    unittest.main()
