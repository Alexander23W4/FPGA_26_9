"""PS fixed-point values survive UART, TCP, stream queuing and GUI formatting."""
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest.mock import patch

import frame_transfer as transfer
from frame_pipeline import FramePipeline
from medical_metrics import VOLUME_NAMES, EF_NAMES, UNAVAILABLE, decode_medical_values
import monitor_network as gui
from test_frame_transfer import running_board

VALUES=(3,288170,11527,6916,8645,5763,28817,11527,23054,11527,6000,5000)


class MedicalMetricsTests(unittest.TestCase):
    def test_uart_uses_ps_values_without_recomputing_ef(self):
        response=''.join('[PL rdbk] %s(0x%02X) = 0\r\n' % (name,reg)
                         for name,reg in gui.PL_REGISTERS.items())
        names=['FLAGS','COEFFICIENT_NANO']+[n+'_ML_X100' for n in VOLUME_NAMES]+[n+'_X100' for n in EF_NAMES]
        response+=''.join('[PS medical] %s = %d\r\n' % pair for pair in zip(names,VALUES))
        with patch.object(gui,'_board_talk',return_value=response):
            result=gui._readback_regs()
        self.assertTrue(result['ok'],result)
        self.assertEqual(result['medical_volumes_ml']['EDV_LV'],'288.17')
        self.assertEqual(result['medical_ef_percent'],{'EF_LV':'60.00','EF_RV':'50.00'})
        self.assertEqual(result['medical_volume_unit'],'mL')
        self.assertTrue(result['medical_scale_assumed'])
        with patch.object(gui,'_board_talk',return_value=response.replace('[PS medical] EF_RV_X100','[truncated] EF_RV_X100')):
            self.assertFalse(gui._readback_regs()['ok'])

    def test_absent_phase_and_invalid_snapshots_are_not_zero_ef(self):
        result=decode_medical_values(3,288170,[UNAVAILABLE]*8,[UNAVAILABLE]*2)
        self.assertTrue(all(value is None for value in result['medical_volumes_ml'].values()))
        self.assertEqual(result['medical_ef_percent'],dict(EF_LV=None,EF_RV=None))
        for flags,coefficient,volumes,efs in (
            (3,288170,[1]*8,[10001,0]),(0,288170,[1]*8,[0,0]),
            (3,0,[1]*8,[0,0]),(4,288170,[1]*8,[0,0])):
            with self.assertRaises(ValueError):
                decode_medical_values(flags,coefficient,volumes,efs)

    def test_fast_tcp_frame_carries_ps_volumes_without_uart_or_disk(self):
        with running_board() as board:
            board.medical_values=VALUES
            client=transfer.FrameTransferClient('127.0.0.1',board.server_address[1],'unused',2)
            self.addCleanup(client.close)
            result=client.receive_frame(bytes(65536))
            self.assertEqual(result['readback']['medical_ef_percent']['EF_LV'],'60.00')
            self.assertEqual(result['readback']['medical_volumes_ml']['ESV_RV'],'115.27')
            self.assertEqual(result['readback']['pl_interval']['elapsed_ms'],20)
            self.assertEqual(len(result['raw']),262144)
            self.assertEqual(board.acks,0)

    def test_pipeline_decodes_new_snapshot_for_each_returned_frame(self):
        with running_board() as board:
            board.medical_values=VALUES
            board.pipeline_min_before_return=4
            pipe=FramePipeline('127.0.0.1',board.server_address[1],3)
            self.addCleanup(pipe.close)
            futures=[pipe.submit({'data':bytes([i])*65536},i) for i in range(4)]
            for future in futures:
                result=future.result(3)
                self.assertEqual(result['readback']['system_mode'],1)
                self.assertEqual(result['readback']['medical_ef_percent']['EF_RV'],'50.00')
                self.assertEqual(result['readback']['medical_volumes_ml']['EDV_RV'],'230.54')
                self.assertEqual(len(result['raw']),262144)

    @unittest.skipUnless(shutil.which('node'),'Node.js required for actual GUI renderer')
    def test_gui_renders_received_values_and_clears_unavailable(self):
        root=Path(__file__).resolve().parents[2]
        result=subprocess.run([shutil.which('node'),str(root/'scripts/tests/gui_medical_metrics.js'),str(root)],
                              capture_output=True,text=True,encoding='utf-8',timeout=15)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('GUI_MEDICAL_METRICS_OK',result.stdout)


if __name__=='__main__':unittest.main()
