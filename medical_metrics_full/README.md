# FPGA 医学影像：连续帧配准 + EDV/ESV/LVEF/应变

本目录是本项目的可直接运行代码包，目标是补齐两个功能：

1. **超声连续帧配准**：相邻帧 ROI、整数平移 SAD 搜索、抛物线亚像素修正、双线性插值。
2. **心脏定量**：LV 腔面积、长轴、ED/ES 帧、EDV、ESV、LVEF、简化 GLS 应变。

> 重要边界：这里的 GLS 是**心内膜边界路径长度/长轴应变的工程替代量**，不是临床斑点追踪 GLS；EDV/ESV 是单平面 area-length 近似，不是临床双平面测量。用于竞赛演示和算法链路验证，不用于诊断。

## 1. 结论：能否复现

| 部分 | 当前状态 | 说明 |
|---|---|---|
| Python 黄金模型 | **已复现** | 11 个回归测试全部通过；CAMUS official testing split 前 8 例全部成功 |
| CAMUS NIfTI 读取 | **已复现** | 不依赖 SimpleITK/nibabel，只用 NumPy |
| 连续帧平移配准 | **已复现** | 合成平移测试精确恢复；CAMUS 真实帧已输出 dx/dy/SAD |
| EDV/ESV/LVEF | **已复现** | 基于 CAMUS GT 掩膜，结果见 `docs/RESULTS.md` |
| 简化 GLS | **已复现** | 基于 ED/ES 心内膜边界路径长度 |
| RTL 功能模块 | **已交付，未本机综合** | 当前机器没有 Vivado/iverilog/Verilator，不能声称已综合/时序收敛 |
| RTL 自检 testbench | **已提供，未本机运行** | 需在 Vivado xsim 或 iverilog 环境执行 |
| 上板实时链路 | **未验证** | 需要队友仓库、Vivado 工程和 ACZ7015 板卡 |
| U-Net 自动掩膜 | **未包含** | 当前用 CAMUS GT 掩膜验证定量链；后续接轻量 U-Net 输出 |

## 2. 目录

```text
medical_metrics/
├─ python/
│  ├─ golden_metrics.py          # 黄金模型
│  ├─ test_golden_metrics.py     # 黄金模型回归测试
│  ├─ rtl_model.py               # RTL 定点算术参考模型
│  ├─ test_rtl_model.py          # RTL 算术回归测试
│  ├─ run_camus.py               # official split 批量运行
│  └─ patient000*_metrics.json   # 已生成结果
├─ rtl/
│  ├─ sync_ram.v                 # 同步双口 RAM
│  ├─ frame_diff_sad.v           # 单候选 SAD
│  ├─ bilinear_interp.v           # Q8 双线性插值
│  ├─ registration_search.v      # ±R 平移搜索
│  ├─ registration_top.v         # 帧级配准包装
│  ├─ area_counter.v             # 掩膜面积
│  ├─ long_axis_extent.v         # 长轴像素长度
│  ├─ div_u64_u64.v              # 64/64 除法器
│  ├─ volume_calc.v              # Q16.16 容积
│  ├─ strain_calc.v              # 简化应变
│  ├─ ed_es_tracker.v            # ED/ES 跟踪
│  ├─ medical_axi_lite.v         # 0x40..0x4F 寄存器
│  └─ medical_accel_top.v        # 顶层包装
├─ sim/
│  ├─ tb_registration_top.v      # 合成平移自检
│  ├─ tb_volume_calc.v           # 容积/应变自检
│  └─ tb_area_axis.v             # 面积/长轴自检
├─ csrc/
│  ├─ medical_metrics.h          # PS 端寄存器定义/结构体
│  └─ medical_metrics.c          # 读取 Q16.16 并换算 mL/%
└─ docs/
   ├─ INTEGRATION.md             # 与队友仓库的实际接口对齐
   ├─ FORMULAS.md                # 公式与定点化
   └─ RESULTS.md                 # 已跑出的结果
```

## 3. Python 快速运行

在本目录下：

```powershell
$py = "C:\Users\13995\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"

# 单元测试
│  ├─ test_golden_metrics.py     # 黄金模型回归测试
│  ├─ rtl_model.py               # RTL 定点算术参考模型
│  ├─ test_rtl_model.py          # RTL 算术回归测试

# 单例 CAMUS
& $py python\golden_metrics.py `
  --patient-dir "C:\Users\13995\Desktop\fpga校赛\CAMUS_public\database_nifti\patient0001" `
  --registration-frames 6 `
  --out python\patient0001_metrics.json

# official testing split 前 8 例
& $py python\run_camus.py --split testing --limit 8 --registration-frames 2 `
  --out-csv python\camus_testing_4CH_metrics.csv
```

如果没有上面的 bundled Python，把 `$py` 换成 `python` 即可。依赖只有 `numpy`。

## 4. RTL 数据流

```text
grayscale stream ──► registration_top ──► reg_dx/reg_dy/reg_sad
        │                  │
        │                  └─ prev/curr 256x256 frame RAM
        │
mask stream ──► area_counter ──► area_px
        └────► long_axis_extent ──► length_px
                                      │
                                      ▼
                                 volume_calc (Q16.16 mL)
                                      │
                                      ▼
                                 ed_es_tracker (ED/ES)
                                      │
                                      ▼
                                 strain_calc (Q16.16 %)
                                      │
                                      ▼
                                 medical_axi_lite (0x40..0x4F)
```

默认参数：`FRAME_W=256`、`FRAME_H=256`、`ROI=48x48`、`SEARCH_R=8`、8-bit 灰度、80 MHz 处理时钟。按 48x48 ROI 计算，SAD 搜索约 1.33M cycles，约 16.6 ms；再加上帧拷贝约 1.6 ms，单帧后处理约 18 ms，理论上可支持约 30 fps，但必须用 Vivado 综合/时序和板级实测确认。

## 5. 与队友仓库的接口

当前队友仓库 `FPGA_26_9-master` 实际实例化的是：

- `rtl/top1.v`
- `rtl/thresholder/top_threshold_demo.v`
- `rtl/thresholder/axi_lite_slave.v`
- `csrc/MID_plt/src/config/pl_cmd.h`

`pl_cmd.h` 用的是 **WORD 索引**，再由 `PL_REG_ADDRESS(index) = 0x44000000 + (index << 2)` 转成字节地址。已有 `0x00/0x01/0x02/0x03/0x04/0x20/0x21/0x22/0x31...`。本包新增的 `0x40..0x4F` 是同一套 WORD 索引的扩展，不与已有寄存器冲突。

注意：仓库里另有 `rtl/axi_lite_rcv.v`，它使用 `0x00/0x10/0x20/0x30...` 的另一套映射，但当前 `top1.v` 并没有实例化它。因此**不要按 `axi_lite_rcv.v` 的 0x10/0x20 去接 PS**，以 `top_threshold_demo + axi_lite_slave + pl_cmd.h` 为准。

详细接线、地址表和合并方法见 `docs/INTEGRATION.md`。

## 6. 推荐落地顺序

1. **先保 Python 报告和视频素材**：直接跑 `run_camus.py`，生成 CSV/JSON，作为算法正确性的证据。
2. **再接 RTL**：先用 `tb_registration_top.v` 验证 `dx/dy/SAD`，再接 `medical_accel_top`。
3. **再接 PS**：把 `csrc/medical_metrics.*` 加入 Vitis 工程，通过 AXI-Lite 读回 Q16.16 结果。
4. **最后接 U-Net**：当前定量链使用 GT 掩膜；竞赛展示时把 U-Net 掩膜接到 `s_axis_tmask`，才是完整的“实时自动分析”。

## 7. 不可夸大之处

- 目前没有在 ACZ7015 上完成综合、时序收敛和板上实测。
- 没有声称 RTL 已通过 xsim/iverilog；testbench 只是可执行的自检代码。
- 没有把 GT 掩膜结果说成 U-Net 实时结果。
- 没有把简化应变说成临床 GLS。



