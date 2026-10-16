"""Offline checks for network frame transfer and the retained UART controls."""
import base64
import io
import sys
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

import numpy as np
from PIL import Image

import monitor_network as gui


END = "\r\n===== END =====\r\n"
UPLOAD_OK = "A: load to eMMC SUCCESSFUL\nRESULT: VERIFY OK\n" + END
FRAME = bytes(range(256)) * 256


class SingleFrameTests(unittest.TestCase):
    def test_original_snapshot_returns_stored_unprocessed_image(self):
        state = gui.web_common.WebState.__new__(gui.web_common.WebState)
        state.lock = threading.Lock()
        state.image = np.arange(256 * 256, dtype=np.uint8).reshape(256, 256)
        state.image_name = "selected.bin"

        result = state.original_snapshot()
        restored = np.asarray(Image.open(io.BytesIO(base64.b64decode(result["image"]))))

        self.assertEqual(result["image_name"], "selected.bin")
        np.testing.assert_array_equal(restored, state.image)

    def test_only_exact_raw_bin_is_accepted(self):
        gui._validate_bin_frame(FRAME, "frame.BIN")
        for data, name in ((FRAME, "frame.png"), (FRAME, "frame"),
                           (FRAME[:-1], "frame.bin"),
                           (FRAME + b"x", "frame.bin")):
            with self.subTest(name=name, size=len(data)), self.assertRaises(ValueError):
                gui._validate_bin_frame(data, name)

    def test_invalid_frame_never_clears_emmc(self):
        with patch.object(gui, "_board_talk_locked") as talk:
            self.assertFalse(gui._do_transfer(FRAME, filename="frame.jpg")["ok"])
            self.assertFalse(gui._do_transfer(FRAME[:-1])["ok"])
            self.assertFalse(gui._do_transfer(FRAME, index=1)["ok"])
            talk.assert_not_called()

    def test_upload_uses_network_without_uart_mode_change_or_emmc(self):
        expected = {"ok": True, "mode": 0, "frames": 1, "bytes": 65536,
                    "output_bytes": 262144, "files": {"png": "x.png"}, "log": "saved"}
        with patch.object(gui._FRAME_CLIENT, "transfer", return_value=expected) as send, \
             patch.object(gui, "_board_talk_locked", return_value='[PL rdbk] VIDEO_MODE(0x02) = 0\n') as uart, \
             patch.object(gui, "_load_to_emmc_locked") as emmc:
            result = gui._do_transfer(FRAME, filename="frame.bin")
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['results'], [expected])
            send.assert_called_once_with(FRAME, "frame.bin")
            uart.assert_not_called()
            emmc.assert_not_called()

    def test_network_failure_is_not_reported_as_success_or_fallback_upload(self):
        with patch.object(gui._FRAME_CLIENT, "transfer", side_effect=ConnectionError("link down")), \
             patch.object(gui, "_board_talk_locked", return_value='[PL rdbk] VIDEO_MODE(0x02) = 0\n') as uart:
            result = gui._do_transfer(FRAME)
            self.assertFalse(result["ok"])
            self.assertIn("link down", result["log"])
            uart.assert_not_called()

    def test_serial_waits_through_silence_and_split_end_marker(self):
        chunks = iter([b"VDMA: sending\r\n"] + [b""] * 8 +
                      [gui.FRAME_DONE_LINE.encode(), b"\r\n===== EN", b"D =====\r\n"])
        serial = Mock()
        serial.read.side_effect = lambda n: next(chunks)
        with patch.dict(sys.modules, {"serial": types.SimpleNamespace(Serial=lambda *a, **k: serial)}):
            result = gui._board_talk_locked(b"D\x00\x00\x00\x00", wait=None)
        self.assertIn(gui.FRAME_DONE_LINE, result)
        self.assertIn("===== END =====", result)
        serial.close.assert_called_once()

    def test_partial_response_times_out_as_failure(self):
        serial = Mock()
        serial.read.return_value = b"still working\r\n"
        with patch.dict(sys.modules, {"serial": types.SimpleNamespace(Serial=lambda *a, **k: serial)}), \
             patch.object(gui.time, "monotonic", side_effect=[0.0, 0.0, 0.6]):
            with self.assertRaises(TimeoutError):
                gui._board_talk_locked(b"E", wait=0.5)
        serial.close.assert_called_once()

    def test_transfer_lock_prevents_interleaving_and_duplicate_send(self):
        entered, release = threading.Event(), threading.Event()
        order, results = [], []
        def send(*args, **kwargs):
            order.append("NET")
            entered.set()
            if not release.wait(2):
                raise RuntimeError("test did not release transfer")
            return {"ok": True, "mode": 0, "output_bytes": 262144, "files": {}, "log": "saved"}
        def read(*args, **kwargs):
            if args[0].startswith(b'V'):
                return '[PL rdbk] VIDEO_MODE(0x02) = 0\n'
            order.append("R")
            return END
        with patch.object(gui._FRAME_CLIENT, "transfer", side_effect=send), \
             patch.object(gui, "_board_talk_locked", side_effect=read):
            worker = threading.Thread(target=lambda: results.append(gui._do_transfer(FRAME)))
            reader = threading.Thread(target=lambda: gui._board_talk(b"R"))
            worker.start()
            try:
                self.assertTrue(entered.wait(1))
                self.assertFalse(gui._do_transfer(FRAME)["ok"])
                reader.start()
                time.sleep(0.02)
                self.assertEqual(order, ["NET"])
            finally:
                release.set()
                worker.join(2)
                if reader.ident is not None:
                    reader.join(2)
            self.assertFalse(worker.is_alive())
            self.assertFalse(reader.is_alive())
            self.assertTrue(results[0]["ok"])
            self.assertEqual(order, ["NET", "R"])

    def test_http_rejects_wrong_suffix_size_and_short_body(self):
        for path, size, body in (("/api/serial/transfer?name=a.png", 65536, FRAME),
                                 ("/api/image?name=a.bin", 65535, FRAME[:-1]),
                                 ("/api/serial/transfer?name=a.bin", 65536, FRAME[:-1])):
            with self.subTest(path=path, size=size), patch.object(gui, "_do_transfer") as send:
                handler = gui.NetworkHandler.__new__(gui.NetworkHandler)
                handler.path = path
                handler.headers = {"Content-Length": str(size)}
                handler.rfile = io.BytesIO(body)
                handler.send_json = Mock()
                handler.do_POST()
                self.assertFalse(handler.send_json.call_args.args[0]["ok"])
                self.assertEqual(handler.send_json.call_args.kwargs["status"], 400)
                send.assert_not_called()

    def test_page_has_one_transfer_and_readback_handler(self):
        page = gui.customize_page(gui.web_common.HTML_PAGE)
        self.assertIn('<title>Heartcare</title>', page)
        self.assertIn('<h1>Heartcare</h1>', page)
        self.assertLess(page.index('<h1>'), page.index('id="systemMode"'))
        self.assertLess(page.index('id="systemMode"'), page.index('id="mode"'))
        for option in ('模拟模式', '图像处理模式', '医学分析模式'):
            self.assertIn(option, page)
        for option in ('去噪处理', '轮廓处理', '二值掩膜处理', '叠加掩膜处理', '伪彩色热力图处理', '全显示'):
            self.assertIn(option, page)
        simulation_section = page.index('<section class="setting-group" data-system-mode="simulation"')
        self.assertLess(page.index('id="fpgaOutputMode"'), simulation_section)
        self.assertLess(page.index('id="maskOpacity"'), simulation_section)
        self.assertIn('id="maskOpacity" type="range" min="0" max="100" value="45"', page)
        self.assertIn('id="maskOpacityUpdate" type="button">掩膜透明度更新', page)
        self.assertNotIn('当前应用：', page)
        script = (gui.web_common.GUI_ASSET_DIR / "heartcare.js").read_text(encoding="utf-8")
        self.assertNotIn("maskOpacityApplied", script)
        self.assertNotIn("maskOpacityUpdate.addEventListener('click',()=>", script)
        self.assertIn("/api/serial/mask_transparency?value=", page)
        self.assertNotIn('id="transfer"', page)
        self.assertIn('id="processingStatus"', page)
        for label in ('原图', '去噪图', '轮廓图', '二值掩膜图', '叠加掩膜图', '伪彩色映射图'):
            self.assertIn(f'<figcaption>{label}</figcaption>', page)
        self.assertIn('id="comparisonPreview" class="comparison-preview" hidden', page)
        self.assertIn('id="comparisonOriginal" alt="原图"', page)
        self.assertIn('id="comparisonProcessedLabel">去噪处理</figcaption>', page)
        self.assertIn('id="fullPreview" class="full-preview" hidden', page)
        script = (gui.web_common.GUI_ASSET_DIR / "heartcare.js").read_text(encoding="utf-8")
        self.assertIn("const showAll=processing&&fpgaOutputMode.value==='5'", script)
        self.assertIn("const showComparison=processing&&!showAll", script)
        self.assertIn("getElementById('comparisonOriginal').src=imageSrc", script)
        self.assertIn("getElementById('fullViewOriginal').src=imageSrc", script)
        self.assertIn('if(systemModePending||revision!==systemModeRevision)return;', script)
        self.assertIn('await reloadOriginalImage();', script)
        self.assertIn('function reloadOriginalImage(){', script)
        self.assertNotIn('imagePicker.click()', script)
        self.assertIn("fetch('/api/original',{cache:'no-store'})", script)
        self.assertIn('accept=".bin"', page)
        self.assertEqual(page.count("async function dshTransfer()"), 1)
        self.assertEqual(page.count("async function dshReadback()"), 1)
        self.assertEqual(page.count("addEventListener('click', dshReadback)"), 1)
        self.assertIn("name=' + encodeURIComponent(file.name)", page)
        self.assertIn("file.size !== 65536", page)
        self.assertIn("/api/network/transfer?", page)
        self.assertIn("/api/network/render?mode=", page)
        self.assertIn("</body></html>", page)


if __name__ == "__main__":
    unittest.main()
