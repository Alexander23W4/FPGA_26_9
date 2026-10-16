"""Offline checks for the GUI's single-frame UART transaction."""
import io
import sys
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

import monitor_network as gui


END = "\r\n===== END =====\r\n"
UPLOAD_OK = "A: load to eMMC SUCCESSFUL\nRESULT: VERIFY OK\n" + END
FRAME = bytes(range(256)) * 256


class SingleFrameTests(unittest.TestCase):
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

    def transfer(self, clear, uploaded, done):
        with patch.object(gui, "_board_talk_locked", side_effect=[clear, done]) as talk, \
             patch.object(gui, "_load_to_emmc_locked", return_value=uploaded) as upload:
            result = gui._do_transfer(FRAME, filename="frame.bin")
            return result, talk, upload

    def test_one_click_uploads_once_and_sends_one_d(self):
        result, talk, upload = self.transfer(
            "RESULT: eMMC CLEARED" + END, (True, UPLOAD_OK),
            gui.FRAME_DONE_LINE + END)
        self.assertTrue(result["ok"])
        self.assertEqual((result["frames"], result["bytes"]), (1, 65536))
        self.assertEqual(talk.call_args_list[1].args, (b"D\x00\x00\x00\x00",))
        self.assertIsNone(talk.call_args_list[1].kwargs["wait"])
        upload.assert_called_once_with(FRAME, gui.EMMC_FIXED_ADDR)

    def test_empty_catalog_clear_is_success(self):
        result, _, _ = self.transfer(
            "RESULT: eMMC 已经是空的" + END, (True, UPLOAD_OK), gui.FRAME_DONE_LINE + END)
        self.assertTrue(result["ok"])

    def test_clear_failure_is_not_hidden_by_cleared_banner(self):
        result, talk, upload = self.transfer(
            ">>> E: eMMC CLEARED <<<\nRESULT: CLEAR FAILED" + END,
            (True, UPLOAD_OK), gui.FRAME_DONE_LINE + END)
        self.assertFalse(result["ok"])
        self.assertEqual(talk.call_count, 1)
        upload.assert_not_called()

    def test_verified_but_unregistered_upload_never_sends_d(self):
        result, talk, _ = self.transfer(
            "RESULT: eMMC CLEARED" + END,
            (True, "RESULT: VERIFY OK 但未登记目录" + END), gui.FRAME_DONE_LINE + END)
        self.assertFalse(result["ok"])
        self.assertEqual(talk.call_count, 1)

    def test_old_started_message_and_failed_d_are_not_success(self):
        for response in ("RESULT: OK -- VDMA started", "RESULT: FAILED (VDMA error)"):
            with self.subTest(response=response):
                result, _, _ = self.transfer(
                    "RESULT: eMMC CLEARED" + END, (True, UPLOAD_OK), response + END)
                self.assertFalse(result["ok"])

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
        entered = threading.Event()
        release = threading.Event()
        order = []
        results = []

        def talk(payload, wait=1.5):
            order.append(payload[:1])
            if payload == b"E":
                entered.set()
                if not release.wait(2):
                    raise RuntimeError("test did not release transfer")
                return "RESULT: eMMC CLEARED" + END
            return gui.FRAME_DONE_LINE + END if payload[:1] == b"D" else END

        def upload(*args):
            order.append(b"A")
            return True, UPLOAD_OK

        with patch.object(gui, "_board_talk_locked", side_effect=talk), \
             patch.object(gui, "_load_to_emmc_locked", side_effect=upload):
            worker = threading.Thread(target=lambda: results.append(gui._do_transfer(FRAME)))
            reader = threading.Thread(target=lambda: gui._board_talk(b"R"))
            worker.start()
            try:
                self.assertTrue(entered.wait(1))
                self.assertFalse(gui._do_transfer(FRAME)["ok"])
                reader.start()
                time.sleep(0.02)
                self.assertEqual(order, [b"E"])
            finally:
                release.set()
                worker.join(2)
                if reader.ident is not None:
                    reader.join(2)
            self.assertFalse(worker.is_alive())
            self.assertFalse(reader.is_alive())
            self.assertTrue(results[0]["ok"])
            self.assertEqual(order, [b"E", b"A", b"D", b"R"])

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
        for option in ('显示叠加掩膜处理', '显示伪彩色热力图处理', '全显示模式'):
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
        self.assertIn("if (e.target.value === '5')", page)
        self.assertIn('accept=".bin"', page)
        self.assertEqual(page.count("async function dshTransfer()"), 1)
        self.assertEqual(page.count("async function dshReadback()"), 1)
        self.assertEqual(page.count("addEventListener('click', dshReadback)"), 1)
        self.assertIn("name=' + encodeURIComponent(file.name)", page)
        self.assertIn("file.size !== 65536", page)
        self.assertIn("</body></html>", page)


if __name__ == "__main__":
    unittest.main()
