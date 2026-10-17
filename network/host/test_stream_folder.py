"""Folder-stream validation and CRC failures on the memory-only GUI path."""
from pathlib import Path
import shutil
import subprocess
import unittest
from urllib.error import HTTPError
from test_fast_stream import fast_server, post_frame
import monitor_network as gui


class StreamFolderTests(unittest.TestCase):
    def test_server_rejects_full_mode_and_unsafe_stream_paths_before_upload(self):
        with fast_server() as (board, client, server, state, base):
            for name, mode in [('001.bin', 5), ('../outside.bin', 0), ('bad.png', 0)]:
                with self.subTest(name=name, mode=mode), self.assertRaises(HTTPError) as caught:
                    post_frame(base, name=name, mode=mode)
                caught.exception.close()
            self.assertEqual(board.uploads, 0)

    @unittest.skipUnless(shutil.which('node'), 'Node.js is required')
    def test_failed_return_stops_loop_and_never_loads_stale_output(self):
        with fast_server() as (board, client, server, state, base):
            board.mode=0;board.bad_crc=True
            stale=Path(client.folder, 'CaseA', '001.bin')
            stale.parent.mkdir();stale.write_bytes(b'old file must not be read or overwritten')
            script=Path(gui.__file__).parents[2]/'scripts/tests/gui_fast_stream.js'
            result=subprocess.run([shutil.which('node'), str(script), gui.__file__, base, 'failure'],
                                  capture_output=True, text=True, encoding='utf-8', timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('FAST_GUI_FAILURE_OK', result.stdout)
            self.assertGreaterEqual(board.uploads, 1)
            self.assertLessEqual(board.uploads, 8, 'only the bounded in-flight set may have reached the board')
            self.assertEqual(board.acks, 0)
            self.assertEqual(stale.read_bytes(), b'old file must not be read or overwritten')


if __name__ == '__main__': unittest.main()
