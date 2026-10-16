"""Stable stream filenames must still be driven by each fresh FPGA response."""
import base64
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import frame_transfer as transfer
from test_frame_transfer import INPUT, RAW, running_board


class StreamResultFilesTests(unittest.TestCase):
    def test_repeated_identical_frames_receive_and_overwrite_the_same_files(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            binary = Path(folder, 'Echo run', 'sub', '001.bin')
            binary.parent.mkdir(parents=True)
            binary.write_bytes(RAW)
            binary.with_suffix('.png').write_bytes(b'old preview')
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            with patch.object(transfer, 'save_result', wraps=transfer.save_result) as save:
                first = client.transfer(INPUT, '001.bin', 4, result_name='Echo run/sub/001.bin')
                second = client.transfer(INPUT, '001.bin', 4, result_name='Echo run/sub/001.bin')
            self.assertNotEqual(first['job'], second['job'])
            self.assertEqual(save.call_count, 2)
            self.assertEqual((board.uploads, board.acks), (2, 2))
            self.assertEqual(first['files'], second['files'])
            self.assertEqual(Path(second['files']['bin']), binary.resolve())
            self.assertEqual(binary.read_bytes(), RAW)
            self.assertEqual(sorted(path.name for path in binary.parent.iterdir()), ['001.bin', '001.png'])
            with Image.open(io.BytesIO(base64.b64decode(second['image']))) as preview:
                self.assertEqual(preview.getpixel((0, 0)), (33, 22, 11))

    def test_mode_change_uses_the_same_name_and_a_fresh_received_result(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            first = client.transfer(INPUT, '001.bin', 4, result_name='clip/001.bin')
            second = client.render(2, '001.bin', result_name='clip/001.bin')
            self.assertEqual(first['files'], second['files'])
            self.assertNotEqual(first['job'], second['job'])
            self.assertEqual(Path(second['files']['bin']).read_bytes()[3::4], bytes([2]) * 65536)
            self.assertEqual((board.uploads, board.renders, board.acks), (1, 1, 2))
            self.assertEqual(list(Path(folder).rglob('*.bin')), [Path(folder, 'clip', '001.bin')])

    def test_invalid_new_response_preserves_previous_result(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            first = client.transfer(INPUT, '001.bin', 4, result_name='clip/001.bin')
            saved = {kind: Path(path).read_bytes() for kind, path in first['files'].items()}
            board.bad_crc = True
            with self.assertRaisesRegex(ValueError, 'CRC'):
                client.transfer(INPUT, '001.bin', 4, result_name='clip/001.bin')
            self.assertEqual((board.uploads, board.acks), (2, 1))
            for kind, path in first['files'].items():
                self.assertEqual(Path(path).read_bytes(), saved[kind])

    def test_pending_job_cannot_change_stable_output_path(self):
        with running_board() as board, tempfile.TemporaryDirectory() as folder:
            client = transfer.FrameTransferClient('127.0.0.1', board.server_address[1], folder, 2)
            with patch.object(transfer, 'save_result', side_effect=PermissionError('disk unavailable')):
                with self.assertRaises(transfer.ResultSaveError):
                    client.transfer(INPUT, '001.bin', 4, result_name='clip/001.bin')
            with self.assertRaisesRegex(RuntimeError, '保存路径'):
                client.transfer(INPUT, '001.bin', 4, result_name='other/001.bin')
            recovered = client.transfer(INPUT, '001.bin', 4, result_name='clip\\001.bin')
            self.assertTrue(recovered['ok'])
            self.assertEqual((board.uploads, board.resumes, board.acks), (1, 1, 1))

    def test_bad_paths_are_rejected_before_connecting(self):
        bad_names = ('', '/a.bin', '../a.bin', 'a/../b.bin', './a.bin', 'a//b.bin',
                     'C:/a.bin', '\\\\server\\a.bin', 'a:stream.bin', 'clip/a?.bin',
                     'clip/a*.bin', 'clip/a|.bin', 'clip/a<.bin', 'clip/a>.bin',
                     'clip/a".bin', 'clip/a\0.bin', 'clip/a\x1f.bin', 'clip./a.bin',
                     'clip /a.bin', 'clip/a.bin ', 'clip/a.bin.', 'clip/a.png',
                     'CON.bin', 'prn.bin', 'AUX.x.bin', 'nul/1.bin', 'com1.bin',
                     'LPT9.bin', 'COM\u00b9.bin', 'con .bin', 'CONIN$.bin',
                     'CONOUT$.bin', b'clip/a.bin', 123)
        with tempfile.TemporaryDirectory() as folder:
            client = transfer.FrameTransferClient(folder=folder)
            with patch.object(transfer.socket, 'create_connection') as connect:
                for name in bad_names:
                    with self.subTest(name=name), self.assertRaises(ValueError):
                        client.transfer(INPUT, 'a.bin', 4, result_name=name)
                connect.assert_not_called()
            self.assertIsNone(client.pending)

    def test_directory_and_file_symlinks_cannot_escape_result_root(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            target = Path(outside, '001.bin')
            target.write_bytes(b'outside')
            try:
                os.symlink(outside, Path(folder, 'linked'), target_is_directory=True)
                os.symlink(target, Path(folder, 'file.bin'))
                os.symlink(target, Path(folder, 'image.png'))
            except OSError as error:
                self.skipTest('creating symlinks is unavailable: ' + str(error))
            for name in ('linked/001.bin', 'file.bin', 'image.bin'):
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'outside'):
                    transfer.save_result(RAW, '001.bin', 4, 123, folder, result_name=name)
            self.assertEqual(target.read_bytes(), b'outside')

    @unittest.skipUnless(os.name == 'nt', 'Windows directory junction check')
    def test_windows_junction_cannot_escape_result_root_without_symlink_privilege(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            link = Path(folder, 'linked')
            create = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), outside],
                                    capture_output=True, text=True)
            self.assertEqual(create.returncode, 0, create.stdout + create.stderr)
            with self.assertRaisesRegex(ValueError, 'outside'):
                transfer.save_result(RAW, '001.bin', 4, 123, folder, result_name='linked/001.bin')
            self.assertFalse(list(Path(outside).iterdir()))

    def test_failed_png_write_keeps_both_old_files_and_cleans_job_temps(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder, 'clip', '001.bin')
            binary.parent.mkdir()
            binary.write_bytes(b'old binary')
            binary.with_suffix('.png').write_bytes(b'old png')
            with patch.object(Image.Image, 'save', side_effect=OSError('disk full')):
                with self.assertRaisesRegex(OSError, 'disk full'):
                    transfer.save_result(RAW, '001.bin', 4, 0x1234, folder, result_name='clip/001.bin')
            self.assertEqual(binary.read_bytes(), b'old binary')
            self.assertEqual(binary.with_suffix('.png').read_bytes(), b'old png')
            self.assertFalse(list(Path(folder).rglob('*.part')))

    def test_files_are_flushed_before_atomic_replacement_with_job_specific_temps(self):
        with tempfile.TemporaryDirectory() as folder:
            replace = os.replace
            calls = []

            def inspect_replace(source, destination):
                calls.append((Path(source), Path(destination)))
                self.assertTrue(Path(source).name.endswith('.aabbccdd.part'))
                if len(calls) == 1:
                    self.assertEqual(len(list(Path(folder).rglob('*.part'))), 2)
                replace(source, destination)

            with patch.object(transfer.os, 'replace', side_effect=inspect_replace), \
                    patch.object(transfer.os, 'fsync', wraps=os.fsync) as flush:
                transfer.save_result(RAW, '001.bin', 4, 0xaabbccdd, folder,
                                     result_name='clip/001.bin')
            self.assertEqual(flush.call_count, 2)
            self.assertEqual(len(calls), 2)
            self.assertFalse(list(Path(folder).rglob('*.part')))

    def test_normal_image_output_keeps_timestamp_mode_and_job_names(self):
        with tempfile.TemporaryDirectory() as folder:
            files = transfer.save_result(RAW, '001.bin', 4, 0x1234, folder)
            self.assertRegex(Path(files['bin']).name, r'^001_heat_\d{8}_\d{6}_\d{6}_00001234\.bin$')
            self.assertEqual(Path(files['png']).with_suffix('.bin'), Path(files['bin']))


if __name__ == '__main__':
    unittest.main()
