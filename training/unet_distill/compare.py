"""Summarize completed trials and explicitly separate compression from quality."""
import argparse
import json
from pathlib import Path

from models import ROOT


def compare(root):
    rows = []
    for path in sorted(root.glob("*/report.json")):
        report = json.loads(path.read_text(encoding="utf-8"))
        profile = report["profile"]
        if "validation_teacher" in report:
            validation = report["validation_teacher"]
            test = report["test_teacher"]
        else:
            validation = report["validation"]["teacher"]
            test = report["test"]["teacher"]
        verification = path.parent / "export/verification.json"
        verified = None
        if verification.exists(): verified = json.loads(verification.read_text(encoding="utf-8"))
        fp = verified.get("fp32_test_teacher", verified.get("fp32_student", {}).get("teacher")) if verified else None
        q = verified.get("int8_weights_test_teacher", verified.get("int8_weights_fp32_activations", {}).get("teacher")) if verified else None
        rows.append({"name": path.parent.name, "macs": profile["macs_per_frame"],
                     "validation_mean_foreground_dice": validation["mean_foreground_dice"],
                     "test_mean_foreground_dice": (fp or test)["mean_foreground_dice"],
                     "test_per_class_dice": (fp or test)["per_class_dice"][1:],
                     "boundary_f1_1px_mean": fp.get("boundary_f1_tolerance_1px_mean") if fp else None,
                     "int8_weights_mean_foreground_dice": q["mean_foreground_dice"] if q else None,
                     "files": verified.get("files") if verified else None,
                     "export": str(verification.parent) if verified else None})
    # Candidate selection uses validation only. The test values are reported
    # after selection, never used to tune the architecture or select weights.
    best = max(rows, key=lambda r: r["validation_mean_foreground_dice"]) if rows else None
    gate = bool(best and best["validation_mean_foreground_dice"] >= .9 and
                best["test_mean_foreground_dice"] >= .9 and min(best["test_per_class_dice"]) >= .85 and
                best["boundary_f1_1px_mean"] is not None and best["boundary_f1_1px_mean"] >= .8)
    quant_path = root / "original_int8/verification.json"
    original_quant = json.loads(quant_path.read_text(encoding="utf-8")) if quant_path.exists() else None
    result = {"teacher_fp32_weight_bytes": 26457792, "teacher_macs": 3373326336, "trials": rows,
              "best_by_validation": best["name"] if best else None,
              "engineering_preservation_gate": {"mean_mask_dice": .9, "minimum_class_mask_dice": .85,
                                                  "mean_boundary_f1_1px": .8, "clinical_standard": False},
              "preservation_gate_passed": gate, "current_fpga_model_changed": False,
              "original_network_weight_quantization_baseline": original_quant,
              "recommendation": "candidate for further independent validation" if gate else "retain original model; student preservation target not met"}
    (root / "comparison.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    lines = ["# 本地蒸馏实验结果", "", "指标均表示与原教师的一致性，不能解释成医生标注准确率。", "",
             "| 实验 | MAC/帧 | 验证前景 Dice | 测试前景 Dice | 轮廓 F1（1px） |", "|---|---:|---:|---:|---:|"]
    for row in rows:
        f1 = "未测" if row["boundary_f1_1px_mean"] is None else f'{row["boundary_f1_1px_mean"]:.4f}'
        lines.append(f'| {row["name"]} | {row["macs"]:,} | {row["validation_mean_foreground_dice"]:.4f} | {row["test_mean_foreground_dice"]:.4f} | {f1} |')
    lines += ["", f'验证集最高：`{result["best_by_validation"]}`。', "",
              "达到本轮工程保留门槛，仍需独立验证。" if gate else "**本轮尚未达到质量保留门槛，保留原模型，不建议替换上板。**", "",
              "尚未进行学生 HLS 综合/上板或完整激活 INT8 推理。细节见 `comparison.json` 和各实验 `export/verification.json`。"]
    if original_quant:
        lines += ["", "## 完整网络的权重 INT8 对照", "",
                  f'权重存储：26,457,792 B → {original_quant["weight_bytes"]:,} B。', "",
                  f'64 张测试帧上，相对原模型的四腔平均 Dice = {original_quant["mean_foreground_dice"]:.6f}，'
                  f'1 像素容差轮廓 F1 = {original_quant["boundary_f1_1px_mean"]:.6f}。', "",
                  "这是完整网络的逐通道权重压缩，保留 FP32 激活验证。没有减少 MAC、没有验证整数推理或板端加速，当前烧录脚本不能直接加载这个紧凑 INT8 文件。"]
    (root / "RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=ROOT / "build/unet_distill")
    compare(p.parse_args().root)
