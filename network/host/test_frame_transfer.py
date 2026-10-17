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
        self.mode=4;self.raw=RAW;self.events=[];self.has_frame=False;self.renders=0
        self.stall_next=False;self.stall_job=None;self.cancels=[]
        self.release_late=threading.Event();self.cancel_seen=threading.Event()
        self.input_images=[];self.error_next=None
        # Optional fresh hardware result generator for stream integration tests.
        # Existing tests retain the original fixed result pixels and event list.
        self.raw_factory=None;self.result_log=[]
        self.connections=0;self.fast=False;self.rgba=False;self.sent=0;self.drop_result=False
        self.threshold=128;self.manual=0;self.alpha=45

class MockHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.server.connections+=1
        self.request.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        while self.handle_one():
            pass

    def handle_one(self):
        board=self.server
        try:
            magic,kind,job,length,checksum,extra=transfer.HEADER.unpack(transfer.recv_exact(self.request,24))
            if magic!=transfer.MAGIC:raise AssertionError('magic')
            if kind==transfer.HELLO_FAST:
                self.request.sendall(transfer.packet(transfer.FAST_READY,job,extra=3))
                return True
            if kind==transfer.CANCEL:
                assert length==checksum==extra==0
                board.cancels.append(job)
                if board.job==job:board.job=0;board.done=False
                board.cancel_seen.set()
                return
            if kind in (transfer.UPLOAD,transfer.UPLOAD_FAST):
                board.fast=kind==transfer.UPLOAD_FAST
                if board.drop_upload:
                    board.drop_upload=False
                    return
                image=transfer.recv_exact(self.request,length)
                if len(image)!=transfer.INPUT_BYTES or checksum!=transfer.crc(image):raise AssertionError('upload bytes/CRC')
                board.input_images.append(image)
                board.uploads+=1;board.job=job;board.has_frame=True
                board.done=False;board.raw=bytes([33,22,11,255] if board.fast or board.rgba else [11,22,33,board.mode])*65536
                if board.raw_factory is not None:
                    board.raw=board.raw_factory(board, image)
                board.events.append(('upload',board.mode))
            elif kind in (transfer.RENDER,transfer.RENDER_FAST):
                board.fast=kind==transfer.RENDER_FAST
                assert length==0 and checksum==0 and extra in range(5)
                assert not board.job or board.done, 'new mode requested before PC save ACK'
                if extra!=board.mode:
                    board.events.append(('mode',extra))
                board.mode=extra
                if not board.has_frame:
                    self.request.sendall(transfer.packet(transfer.CONFIGURED,job,extra=extra))
                    return True
                board.renders+=1;board.job=job;board.done=False
                board.raw=bytes([33,22,11,255] if board.fast or board.rgba else [11,22,33,board.mode])*65536
                if board.raw_factory is not None:
                    board.raw=board.raw_factory(board, board.input_images[-1])
                board.events.append(('render',extra))
            elif kind==transfer.RESUME:
                board.resumes+=1
                if job!=board.job:
                    message=b'upload required'
                    self.request.sendall(transfer.packet(transfer.ERROR,job,len(message),0,1)+message)
                    return
                if board.done and not board.fast:
                    self.request.sendall(transfer.packet(transfer.DONE,job,0,board.last_crc,board.mode))
                    return True
            else:raise AssertionError('unexpected request')
            raw=board.raw
            result_mode=board.mode
            board.result_log.append((job,result_mode,raw))
            if board.error_next:
                message=board.error_next.encode();board.error_next=None
                self.request.sendall(transfer.packet(transfer.ERROR,job,len(message),0,2)+message)
                return
            if board.stall_next:
                board.stall_next=False;board.stall_job=job
                board.release_late.wait(5)
            meta=transfer.META.pack(3,0,board.manual,result_mode,board.threshold,board.threshold,1234,board.alpha,
                                    1000,500,25000,504000,126000,board.uploads-1)
            payload=meta+raw if board.fast else raw
            length=len(payload)-1 if board.bad_length else len(payload)
            checksum=transfer.crc(payload)^(1 if board.bad_crc else 0)
            header=transfer.packet(transfer.RESULT_FAST if board.fast else transfer.RESULT_RGBA if board.rgba else transfer.RESULT,job,length,checksum,result_mode)
            if board.drop_result:
                board.drop_result=False;self.request.sendall(header+payload[:100]);return
            self.request.sendall(header[:7]);self.request.sendall(header[7:]+payload)
            if board.fast:
                board.sent+=1;board.done=True;board.last_crc=transfer.crc(payload)
                board.events.append(('sent',board.mode))
                return True
            magic,kind,ack_job,ack_len,ack_crc,mode=transfer.HEADER.unpack(transfer.recv_exact(self.request,24))
            if (magic,kind,ack_job,ack_len,ack_crc,mode)!=(transfer.MAGIC,transfer.SAVED,job,len(payload),transfer.crc(payload),result_mode):
                raise AssertionError('invalid save ACK')
            board.check_saved()
            board.acks+=1;board.done=True
            board.last_crc=transfer.crc(payload)
            board.events.append(('ack',board.mode))
            if board.lose_done:
                board.lose_done=False
                return
            self.request.sendall(transfer.packet(transfer.DONE,job,0,transfer.crc(payload) ^ int(board.bad_done),board.mode))
            return True
        except (OSError,ConnectionError):
            pass

@contextlib.contextmanager
def running_board():
    board=MockBoard()
    thread=threading.Thread(target=board.serve_forever,daemon=True);thread.start()
    try:yield board
    finally:board.release_late.set();board.shutdown();board.server_close();thread.join(2)

class FrameTransferTests(unittest.TestCase):
    def test_timeout_discards_job_without_resume_and_next_image_starts_fresh(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            board.stall_next=True
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,.2)
            with self.assertRaisesRegex(TimeoutError,'已取消'):
                client.transfer(INPUT,'expired.bin')
            self.assertIsNone(client.pending)
            self.assertTrue(board.cancel_seen.wait(1))
            self.assertEqual(board.cancels,[board.stall_job])
            self.assertEqual((board.uploads,board.resumes,board.acks),(1,0,0))
            self.assertFalse(list(Path(folder).glob('*.bin')))
            client.timeout=2
            result=client.transfer(INPUT[::-1],'fresh.bin')
            self.assertTrue(result['ok'])
            self.assertNotEqual(result['job'],board.stall_job)
            board.release_late.set()
            self.assertEqual((board.uploads,board.resumes,board.acks),(2,0,1))
            self.assertEqual(board.input_images[-1],INPUT[::-1])
            self.assertTrue(all(path.name.startswith('fresh_') for path in Path(folder).iterdir()))

    def test_render_timeout_clears_pending_and_does_not_resume(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            client.transfer(INPUT,'a.bin')
            board.stall_next=True;client.timeout=.2
            with self.assertRaises(TimeoutError):client.render(2,'a.bin')
            self.assertIsNone(client.pending)
            self.assertTrue(board.cancel_seen.wait(1))
            self.assertEqual((board.renders,board.resumes,board.acks),(1,0,1))
            client.timeout=2
            self.assertTrue(client.transfer(INPUT,'different.bin')['ok'])
            self.assertEqual((board.uploads,board.acks),(2,2))

    def test_board_reported_timeout_also_discards_the_job(self):
        with running_board() as board,tempfile.TemporaryDirectory() as folder:
            board.error_next='DMA/PL timeout; reset board'
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],folder,2)
            with self.assertRaises(TimeoutError):client.transfer(INPUT,'expired.bin')
            self.assertIsNone(client.pending)
            self.assertTrue(board.cancel_seen.wait(1))
            self.assertEqual((board.resumes,board.acks),(0,0))

    def test_fragmented_header_cannot_extend_the_transaction_deadline(self):
        clock=[0.0]
        class SlowSocket:
            def settimeout(self,value):pass
            def recv(self,count):
                clock[0]+=.03
                return b'x'
        with patch.object(transfer.time,'monotonic',side_effect=lambda:clock[0]):
            with self.assertRaises(TimeoutError):transfer.recv_exact(SlowSocket(),24,.1)
        self.assertLess(clock[0],.2)

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
