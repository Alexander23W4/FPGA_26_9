import contextlib
from pathlib import Path
import socket
import socketserver
import tempfile
import threading
import unittest
from unittest.mock import patch
from PIL import Image
import frame_transfer as transfer

INPUT=bytes(range(256))*256
RAW=bytes([11,22,33,4])*65536

class MockBoard(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
    def __init__(self):
        super().__init__(('127.0.0.1',0),MockHandler)
        self.job=0;self.done=False;self.uploads=0;self.acks=0;self.resumes=0
        self.bad_crc=False;self.bad_length=False;self.lose_done=False;self.drop_upload=False;self.bad_done=False
        self.check_saved=lambda:None
        self.mode=4;self.raw=RAW;self.events=[]

class MockHandler(socketserver.BaseRequestHandler):
    def handle(self):
        board=self.server
        try:
            magic,kind,job,length,checksum,extra=transfer.HEADER.unpack(transfer.recv_exact(self.request,24))
            if magic!=transfer.MAGIC:raise AssertionError('magic')
            if kind==transfer.UPLOAD:
                if board.drop_upload:
                    board.drop_upload=False
                    return
                image=transfer.recv_exact(self.request,length)
                if image!=INPUT or checksum!=transfer.crc(INPUT):raise AssertionError('upload bytes/CRC')
                board.uploads+=1;board.job=job
                board.done=False;board.raw=bytes([11,22,33,board.mode])*65536
                board.events.append(('upload',board.mode))
            elif kind==transfer.RESUME:
                board.resumes+=1
                if job!=board.job:
                    message=b'upload required'
                    self.request.sendall(transfer.packet(transfer.ERROR,job,len(message),0,1)+message)
                    return
                if board.done:
                    self.request.sendall(transfer.packet(transfer.DONE,job,0,transfer.crc(board.raw),board.mode))
                    return
            else:raise AssertionError('unexpected request')
            raw=board.raw
            length=len(raw)-1 if board.bad_length else len(raw)
            checksum=transfer.crc(raw)^(1 if board.bad_crc else 0)
            header=transfer.packet(transfer.RESULT,job,length,checksum,board.mode)
            self.request.sendall(header[:7]);self.request.sendall(header[7:]+raw)
            magic,kind,ack_job,ack_len,ack_crc,mode=transfer.HEADER.unpack(transfer.recv_exact(self.request,24))
            if (magic,kind,ack_job,ack_len,ack_crc,mode)!=(transfer.MAGIC,transfer.SAVED,job,len(raw),transfer.crc(raw),board.mode):
                raise AssertionError('invalid save ACK')
            board.check_saved()
            board.acks+=1;board.done=True
            board.events.append(('ack',board.mode))
            if board.lose_done:
                board.lose_done=False
                return
            self.request.sendall(transfer.packet(transfer.DONE,job,0,transfer.crc(raw) ^ int(board.bad_done),board.mode))
        except (OSError,ConnectionError):
            pass

@contextlib.contextmanager
def running_board():
    board=MockBoard()
    thread=threading.Thread(target=board.serve_forever,daemon=True);thread.start()
    try:yield board
    finally:board.shutdown();board.server_close();thread.join(2)

class FrameTransferTests(unittest.TestCase):
    def test_upload_save_then_ack_and_png_channels(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            def saved():
                bins=list(Path(folder).glob('*.bin'));pngs=list(Path(folder).glob('*.png'))
                self.assertEqual(len(bins),1);self.assertEqual(bins[0].read_bytes(),RAW)
                with Image.open(pngs[0]) as image:
                    self.assertEqual(image.size,(256,256));self.assertEqual(image.getpixel((0,0)),(33,22,11))
            board.check_saved=saved
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            result=client.transfer(INPUT,'../../original.bin')
            self.assertTrue(result['ok']);self.assertEqual((board.uploads,board.acks),(1,1))
            self.assertEqual(Path(result['files']['png']).parent,Path(folder).resolve())
            self.assertFalse(list(Path(folder).glob('*.part')))

    def test_disk_failure_sends_no_ack_and_same_job_can_resume(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            with patch.object(transfer,'save_result',side_effect=PermissionError('disk not writable')):
                with self.assertRaises(transfer.ResultSaveError):client.transfer(INPUT,'a.bin')
            self.assertEqual(board.acks,0)
            with self.assertRaisesRegex(RuntimeError,'尚未确认'):client.transfer(INPUT[::-1],'b.bin')
            self.assertTrue(client.transfer(INPUT,'a.bin')['ok'])
            self.assertEqual((board.uploads,board.resumes,board.acks),(1,1,1))

    def test_lost_done_does_not_upload_or_ack_twice(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            board.lose_done=True
            result=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2).transfer(INPUT,'a.bin')
            self.assertTrue(result['ok']);self.assertEqual((board.uploads,board.resumes,board.acks),(1,1,1))
            self.assertEqual(len(list(Path(folder).glob('*.bin'))),1)

    def test_disconnect_before_upload_can_restart_without_starting_two_jobs(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            board.drop_upload=True
            self.assertTrue(transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2).transfer(INPUT,'a.bin')['ok'])
            self.assertEqual((board.uploads,board.acks),(1,1))

    def test_bad_crc_and_length_never_acknowledge_or_save(self):
        for attribute in ('bad_crc','bad_length'):
            with self.subTest(attribute=attribute),running_board() as board,tempfile.TemporaryDirectory() as folder:
                setattr(board,attribute,True)
                client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
                with self.assertRaises(ValueError):client.transfer(INPUT,'a.bin')
                self.assertEqual(board.acks,0);self.assertFalse(list(Path(folder).iterdir()))

    def test_done_must_match_the_saved_result(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            board.bad_done=True
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            with self.assertRaisesRegex(ValueError,'did not confirm'):client.transfer(INPUT,'a.bin')
            self.assertIsNotNone(client.pending)
            board.bad_done=False
            self.assertTrue(client.transfer(INPUT,'a.bin')['ok'])
            self.assertEqual((board.uploads,board.acks),(1,1))

    def test_unexpected_mode_never_saves_or_acknowledges(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            with self.assertRaisesRegex(ValueError,'mode mismatch'):
                client.transfer(INPUT,'a.bin',expected_mode=0)
            self.assertEqual(board.acks,0)
            self.assertFalse(list(Path(folder).iterdir()))

    def test_file_must_still_be_valid_before_ack(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            save=transfer.save_result
            def corrupt(*args):
                files=save(*args)
                Path(files['bin']).write_bytes(b'partial')
                return files
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            with patch.object(transfer,'save_result',side_effect=corrupt):
                with self.assertRaisesRegex(ValueError,'CRC'):
                    client.transfer(INPUT,'a.bin')
            self.assertEqual(board.acks,0)

if __name__=='__main__':unittest.main()
