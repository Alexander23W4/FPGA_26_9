"""Full-duplex transport checks with a peer withholding all results until full."""
import threading
import unittest

from frame_pipeline import FramePipeline
from queued_stream import QueuedStream
from test_frame_transfer import running_board


class FramePipelineTests(unittest.TestCase):
    def test_four_uploads_arrive_before_first_result_without_waiting_for_gui(self):
        with running_board() as board:
            board.pipeline_min_before_return=4
            board.raw_factory=lambda b,image: bytes([image[0],22,33,255])*65536
            pipe=FramePipeline('127.0.0.1',board.server_address[1],3)
            self.addCleanup(pipe.close)
            futures=[pipe.submit({'data':bytes([value])*65536},value%5) for value in range(4)]
            self.assertTrue(board.pipeline_received.wait(2), 'all four uploads must precede any result')
            for value,future in enumerate(futures):
                result=future.result(3)
                self.assertEqual(result['mode'],value%5)
                self.assertEqual(result['raw'],bytes([value,22,33,255])*65536)
                self.assertEqual(result['readback']['ps_detail']['tcp_window_bytes'],65535)
            self.assertEqual((board.uploads,board.acks,board.connections),(4,0,1))

    def test_scheduler_pause_drains_all_dispatched_frames_before_control(self):
        with running_board() as board:
            board.pipeline_min_before_return=4
            board.stall_next=True
            pipe=FramePipeline('127.0.0.1',board.server_address[1],3)
            stream=QueuedStream(lambda *_:self.fail('serial callback used'),pipe.close,pipeline=pipe)
            self.addCleanup(lambda:stream.close(3))
            for i in range(4):stream.enqueue({'data':bytes([i])*65536,'sequence':i,'name':'%d.bin'%i})
            stream.control('resume')
            self.assertTrue(board.pipeline_received.wait(2))
            paused=threading.Event()
            waiter=threading.Thread(target=lambda:(stream.control('pause'),paused.set()))
            waiter.start()
            self.assertFalse(paused.wait(.05))
            board.release_late.set()
            self.assertTrue(paused.wait(3))
            waiter.join(1)
            self.assertEqual(stream.snapshot()['completed'],4)
            self.assertEqual(stream.snapshot()['inflight'],0)

    def test_bad_result_fails_pending_frames_without_reupload_or_partial_preview(self):
        with running_board() as board:
            board.pipeline_min_before_return=4;board.bad_crc=True
            pipe=FramePipeline('127.0.0.1',board.server_address[1],3)
            self.addCleanup(pipe.close)
            futures=[pipe.submit({'data':bytes([i])*65536},0) for i in range(4)]
            for future in futures:
                with self.assertRaisesRegex(ValueError,'CRC'):future.result(3)
            self.assertEqual((board.uploads,board.acks,board.resumes),(4,0,0))


if __name__=='__main__':unittest.main()
