import sys
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT.parent))
sys.path.insert(0, str(ROOT.parent / 'mock'))

import protocol as proto
import web_common
from mock_ps_server import MockPS
from monitor_network import TcpControlWorker, TcpImageSender

IMAGE = r'C:/Users/13995/Desktop/fpga校赛/camus_processed/images/training/patient0001/patient0001_4CH_ED.png'

class NetworkIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mock = MockPS('127.0.0.1', 5200, 5201)
        threading.Thread(target=cls.mock.control_loop, daemon=True).start()
        threading.Thread(target=cls.mock.image_loop, daemon=True).start()
        time.sleep(0.2)

    @classmethod
    def tearDownClass(cls):
        cls.mock.stop_event.set()

    def test_control_and_image(self):
        state = web_common.WebState(IMAGE, False)
        worker = TcpControlWorker(state, '127.0.0.1', 5200)
        worker.start()
        deadline = time.time() + 3
        while not state.serial_connected and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(state.serial_connected)
        self.assertTrue(worker.write(proto.encode_set_threshold(166)))
        self.assertTrue(worker.write(proto.encode_set_mode(1)))
        self.assertTrue(worker.write(proto.encode_start_analyze()))
        result = TcpImageSender('127.0.0.1', 5201, 4096).send_file(IMAGE, 9)
        self.assertGreater(result['Mbps'], 1.0)
        deadline = time.time() + 3
        while time.time() < deadline:
            if state.status.get('frame_id') == 9 and state.mask is not None:
                break
            time.sleep(0.05)
        self.assertEqual(state.status.get('frame_id'), 9)
        self.assertEqual(state.status.get('threshold'), 166)
        self.assertEqual(state.status.get('mode'), 1)
        self.assertEqual(state.mask.shape, (256, 256))
        worker.stop()

if __name__ == '__main__':
    unittest.main(verbosity=2)
