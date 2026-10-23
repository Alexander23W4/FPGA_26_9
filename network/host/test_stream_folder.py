"""Folder-stream validation and CRC failures on the memory-only GUI path."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from test_fast_stream import fast_server, post_frame
import monitor_network as gui


class StreamFolderTests(unittest.TestCase):
    def test_dataset_picker_starts_at_root_and_catalogs_only_selected_patient(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder, 'Camus')
            patient = root / 'testing' / 'patient0047'
            other = root / 'training' / 'patient0001'
            patient.mkdir(parents=True); other.mkdir(parents=True)
            (patient / 'frame001.bin').write_bytes(bytes(gui.FRAME_BYTES))
            (patient / 'frame002.bin').write_bytes(bytes(gui.FRAME_BYTES))
            (other / 'frame001.bin').write_bytes(bytes(gui.FRAME_BYTES))

            class FakeTk:
                def withdraw(self): pass
                def attributes(self, *_args): pass
                def destroy(self): pass

            with patch.dict(gui.STREAM_DATASETS, {'camus': ('Camus', root)}), \
                 patch('tkinter.Tk', return_value=FakeTk()), \
                 patch('tkinter.filedialog.askdirectory', return_value=str(patient)) as picker:
                _, selected_root, selected = gui._choose_dataset_folder('camus')
                _, entries = gui._dataset_catalog('camus', selected)

            self.assertEqual(selected_root, root.resolve())
            self.assertEqual(selected, patient.resolve())
            self.assertEqual(picker.call_args.kwargs['initialdir'], str(root.resolve()))
            self.assertEqual([entry['path'] for entry in entries], [
                'testing/patient0047/frame001.bin',
                'testing/patient0047/frame002.bin',
            ])

    def test_dataset_catalog_rejects_dataset_root_and_outside_folder(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            root = Path(folder, 'Camus'); root.mkdir()
            with patch.dict(gui.STREAM_DATASETS, {'camus': ('Camus', root)}):
                with self.assertRaisesRegex(ValueError, 'patient'):
                    gui._dataset_catalog('camus', root)
                with self.assertRaisesRegex(ValueError, '位于'):
                    gui._dataset_catalog('camus', outside)

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
