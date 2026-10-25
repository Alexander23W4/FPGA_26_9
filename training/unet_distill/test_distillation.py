"""Local correctness checks for teacher recovery, grouping, losses and export."""
import json
from pathlib import Path
import tempfile
import unittest
import contextlib
import io

import numpy as np
import torch

from models import ROOT, Student, Teacher, profile
from prepare import patient_id
from train import dice_loss, confusion, metrics
from export import folded, serialize
from decoder_student import DecoderStudent
from export_decoder import export_hls_graph, quantize


class DistillationChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(2)

    def test_teacher_matches_checked_full_reference(self):
        image = np.fromfile(ROOT / "build/unet/input.bin", np.uint8).reshape(256, 256)
        expected = np.fromfile(ROOT / "build/unet/numpy_reference.logits", "<f4").reshape(256, 256, 5)
        with torch.inference_mode():
            result = Teacher().eval()(torch.from_numpy(image.copy()).float()[None, None] / 255)
        actual = result[0].permute(1, 2, 0).numpy()
        self.assertLess(float(np.max(np.abs(actual - expected))), .003)
        self.assertTrue(np.array_equal(actual.argmax(-1), expected.argmax(-1)))

    def test_patient_grouping_handles_spelling_and_view(self):
        self.assertEqual(patient_id(Path("patient1-4_image.nii.gz")), patient_id(Path("patient-1-2_image.nii.gz")))
        self.assertEqual(patient_id(Path("patient0001-4_image.nii.gz")), "patient-1")
        self.assertNotEqual(patient_id(Path("normal-1-4_image.nii.gz")), "patient-1")

    def test_cache_partitions_have_no_patient_overlap(self):
        root = ROOT / "build/unet_distill/cache_patient"
        patients = json.loads((root / "patients.json").read_text(encoding="utf-8"))
        for a, b in (("train", "validation"), ("train", "test"), ("test", "validation")):
            self.assertFalse(set(patients[a]) & set(patients[b]))
        for row in json.loads((root / "samples.json").read_text(encoding="utf-8")):
            self.assertEqual(patient_id(Path(row["source"])), row["patient"])
            self.assertIn(row["patient"], patients[row["split"]])

    def test_background_does_not_hide_missing_chambers(self):
        target = torch.zeros(1, 32, 32, dtype=torch.long)
        target[:, :2, :2] = 1
        result = metrics(confusion(torch.zeros_like(target), target))
        self.assertGreater(result["pixel_agreement"], .99)
        self.assertEqual(result["mean_foreground_dice"], 0)
        self.assertEqual(metrics(confusion(target, target))["mean_foreground_dice"], 1)

    def test_student_loss_backpropagates(self):
        torch.manual_seed(2609)
        model = Student(4)
        output = model(torch.rand(2, 1, 256, 256))
        labels = torch.randint(0, 5, (2, 256, 256))
        loss = dice_loss(output, labels)
        loss.backward()
        self.assertTrue(torch.isfinite(model.head.weight.grad).all())
        self.assertGreater(float(model.head.weight.grad.abs().sum()), 0)

    def test_compact_export_readback_matches_quantized_parameters(self):
        torch.manual_seed(2609)
        model = Student(2).eval()
        x = torch.rand(1, 1, 256, 256)
        fused = folded(model)
        with torch.inference_mode():
            self.assertTrue(torch.allclose(model(x), fused(x), atol=1e-5))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            quant, manifest = serialize(fused, root)
            payload = (root / "weights_int8.bin").read_bytes()
            actual = dict(quant.named_modules())
            for layer in manifest["layers"]:
                count = layer["weight_elements"]
                channels = layer["shape_oihw"][0]
                weights = np.frombuffer(payload, "i1", count, layer["int8_weight_offset_bytes"]).reshape(layer["shape_oihw"])
                scales = np.frombuffer(payload, "<f4", channels, layer["int8_scale_offset_bytes"])
                reconstructed = weights * scales[:, None, None, None]
                self.assertTrue(np.array_equal(reconstructed, actual[layer["name"]].weight.detach().numpy()))
            self.assertFalse(manifest["activations_quantized"])
            self.assertLess(len(payload), profile(Student(2))["fp32_parameter_bytes"])

    def test_accuracy_first_encoder_and_export_graph(self):
        teacher = Teacher().eval()
        model = DecoderStudent(16).eval()
        model.initialize_from_teacher()
        for key, value in model.encoder.state_dict().items():
            self.assertTrue(torch.equal(value, teacher.state_dict()[key]))
        self.assertFalse(any("decoder" in key for key in model.encoder.state_dict()))
        fused = folded(model)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph = export_hls_graph(fused, root / "fp32_hls")
            self.assertEqual(graph["macs_per_frame"], 585818112)
            image = np.fromfile(ROOT / "build/unet/input.bin", np.uint8).reshape(256, 256)
            image.tofile(root / "image.bin")
            from reference import run
            with contextlib.redirect_stdout(io.StringIO()):
                run(root / "fp32_hls", root / "image.bin", root / "reference")
            reference = np.fromfile(root / "reference.logits", "<f4").reshape(256, 256, 5)
            with torch.inference_mode():
                actual = fused(torch.from_numpy(image.copy()).float()[None, None] / 255)[0].permute(1, 2, 0).numpy()
            self.assertTrue(np.allclose(actual, reference, atol=3e-3, rtol=2e-3))
            quant, manifest = quantize(fused, root)
            self.assertTrue(any(layer["name"].startswith("encoder.") for layer in manifest["layers"]))
            self.assertEqual(len(manifest["layers"]), sum(op["kind"] in (0, 1) for op in teacher.graph["ops"]))

    def test_feature_hint_reconstructs_original_logits(self):
        image = np.fromfile(ROOT / "build/unet/input.bin", np.uint8).reshape(256, 256)
        x = torch.from_numpy(image.copy()).float()[None, None] / 255
        model = Teacher().eval()
        hint_model = Teacher(last_feature=True).eval()
        index = next(i for i, o in enumerate(model.graph["ops"]) if o["name"] == "segmentation_head")
        with torch.inference_mode():
            hint = hint_model(x)
            reconstructed = torch.nn.functional.conv2d(hint, getattr(model, f"weight_{index}"),
                                                       getattr(model, f"bias_{index}"), padding=1)
            self.assertTrue(torch.equal(model(x), reconstructed))
            self.assertEqual(hint.shape, (1, 16, 256, 256))


if __name__ == "__main__":
    unittest.main()
