# Heartcare FPGA 图像处理与医学分析

本项目运行于小梅哥 ACZ7015，FPGA 型号 xc7z015clg485-2。GUI 用于发送 256×256、8-bit 灰度图或 patient 图像流；PL 执行图像处理或医学分析，并可将 HDMI 画面及处理图回传 PC。

> 当前 U-Net 保留完整 FP32 模型，目标是正确接通并验证硬件路径。完整网络尚未做当前版本的整工程实现和上板测试；不要把局部仿真通过理解为医学结果已验证或流式帧率已达标。

## 当前数据通路

### 图像处理模式

```text
GUI → 本机 Python/TCP → PS DDR/VDMA → AXI-Stream
    → denoise/threshold → 双帧缓存
    ├─ HDMI
    └─ S2MM → PS/TCP → PC Python → GUI
```

静态图模式处理一张图；流模式按输入帧持续发送。正常图像处理流不会把每个回传结果保存到磁盘。

### 医学分析模式

```text
AXI-Stream → DDR 帧配准 → 完整四腔 U-Net → EDV/ESV 容积统计
            → LA/RA/LV/RV 掩膜和轮廓 → HDMI/PC 回传
```

医学模式还支持 Cardiac patient 的离线分割缓存：对原始序列先运行完整分割与单独的 PL 掩膜转轮廓步骤，将注册灰度、掩膜、轮廓存回 patient 文件夹。全部帧校验通过后，后续“开始流分析”从缓存输入，绕过配准和 U-Net，保留医学指标、显示和回传。操作和缓存格式见[医学 patient 缓存说明](docs/design/medical_patient_cache.md)。

## U-Net 性能和限制

当前 PL 实现保留完整原网络，FP32、32 路乘加并行、单独 160 MHz U-Net 时钟，权重和中间特征放 DDR，BRAM 用于可复用 tile。模型约 33.73 亿 MAC/帧；仅乘加的理想下限约 659 ms/帧，理想上限约 1.52 FPS，真实速度还会更低。因此当前方案达不到 10 FPS，也不能用作实时 U-Net 视频分割。离线缓存避免重复推理，但首次分割仍需等待模型计算。

模型资源、时钟跨域、DDR 地址、数值精度及验证结果详见 [U-Net 设计说明](rtl/unet/README.md)。缓存分析和 GUI 本地流程详见 [医学 patient 缓存说明](docs/design/medical_patient_cache.md)。

## GUI

在仓库根目录的 Git Bash 中启动：

```bash
bash ./network/launch_gui.sh
```

Python GUI 可连接真实板端，也提供本地 mock PS 服务用于无板开发。Cardiac patient 需要选择单个 patient 文件夹，不要选择整个数据集根目录。

## 构建与烧录

所有源码修改后，在仓库根目录的 Git Bash 中构建 Zynq 硬件和 PS 固件：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f
```

医学模式还需要把与当前硬件版本匹配的 U-Net 权重写入 DDR，再启动 PS：

```bash
UNET_WEIGHTS="$(cygpath -w build/unet/model/weights.bin)" bash scripts/flash_current.sh init
```

断电会清除 DDR 权重。图像处理模式不要求加载 U-Net 权重；医学 U-Net 分割在权重缺失或版本不匹配时会报错停止。修改 32 路 HLS 或权重后，先运行 bash rtl/unet/tools/build.sh 重新生成，再完整构建和加载。

## 目录

| 路径 | 内容 |
|---|---|
| rtl/ | FPGA 顶层、图像处理、配准、医学分析、U-Net 与显示逻辑 |
| rtl/unet/hls/ | 完整模型 HLS 源码与并行卷积结构 |
| rtl/unet/generated/ | 由 HLS 生成的 U-Net Verilog、ROM 和指纹文件 |
| csrc/MID_plt/src/ | Zynq PS 裸机应用、VDMA、TCP 与 PL 控制 |
| network/host/ | Python 服务、浏览器 GUI 和 patient 缓存流程 |
| sim/tb/, scripts/tests/ | RTL testbench 与本地回归测试 |
| docs/design/ | 架构、板测记录及功能设计说明 |
| build/ | 工程产物、资源报告、测试输出和日志 |

## 验证状态

本地已通过 32 路卷积核 C/RTL 协同仿真、完整模型数值参考检查、医疗缓存路径 RTL/PS/GUI 测试和 112 项 Python 主机侧测试（1 项因本机符号链接权限跳过）。当前完整顶层 RTL 综合预算为 92/95 BRAM tile，Block Design 资源尚未计入。完整 Vivado implementation 和新版上板速度仍需用户构建和实测；详细数据和未验证边界见 [U-Net 设计说明](rtl/unet/README.md)。
