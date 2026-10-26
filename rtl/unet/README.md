# 四腔 U-Net：完整 FP32 模型与硬件边界

本目录保留同事提供的完整 `smp.Unet(encoder_name="mobilenet_v2", in_channels=1, classes=5)` 推理模型。原始 `ip/ai4chamberseger` 未改动。此实现用于验证模型和 PL 数据通路；它不是实时分割引擎，医学准确性也尚未验证。

## PL 数据通路

```text
AXI-Stream → 医学模式选择
              → DDR 配准 → 完整 U-Net → EDV/ESV 容积统计
              → 四腔室颜色/轮廓 → 双帧缓存 → HDMI / S2MM 回传
```

U-Net 输出原灰度、LA/RA/LV/RV 四路 mask 和 contour。像素流使用 `valid/ready/eof` 握手；下游反压时数据与标记保持。网络按完整帧接收、计算并输出，不能像逐像素滤波器那样即时产生对应像素。

## 模型与精度

- 78 个算子覆盖 MobileNetV2 编码器、深度/逐点/普通卷积、残差、U-Net 解码器、跳跃连接和五分类输出；62 个 BatchNorm 依 eval 公式折叠。
- 推理使用 FP32，BN epsilon 为 `1e-5`；没有量化或蒸馏。权重是同事导出的六位小数参数，不等同于未提供的训练 checkpoint 逐位数据。
- 输入是 256×256、8-bit 灰度，按 `pixel/255` 归一化；网络输入先经过帧配准。
- 最终类别用 argmax 直接写入行缓存，再形成四路 one-hot 掩膜和四邻域轮廓。输出类别不再从 DDR 浮点副本读回转换。
- 类别暂按同事代码沿用：0 背景、1 LA、2 RA、3 LV、4 RV，`UNET_CLASS_MAP=16'h4321`。尚未用训练标注图确认解剖对应关系。

与模型结构对应的公开实现版本见 [SMP MobileNet 编码器](https://github.com/qubvel-org/segmentation_models.pytorch/blob/v0.3.4/segmentation_models_pytorch/encoders/mobilenet.py)、[SMP U-Net 解码器](https://github.com/qubvel-org/segmentation_models.pytorch/blob/v0.3.4/segmentation_models_pytorch/decoders/unet/decoder.py)和 [Torchvision MobileNetV2](https://github.com/pytorch/vision/blob/v0.17.2/torchvision/models/mobilenetv2.py)。

## 卷积核与时钟

卷积核心采用 **32 路 FP32 乘加并行**、64 像素 tile、16 输入通道 tile、每组最多 64 输出通道。Feature fetch、weight fetch、MAC 和结果写回由四个 HLS dataflow 任务重叠执行。Feature tile 在输出通道间复用，显式 4 KiB feature cache 配合 4 KiB feature FIFO 和 1 KiB kernel FIFO；累加器和逐通道临时值用 LUTRAM。继续增加 BRAM cache 会与整机存储预算冲突。

U-Net 使用单独 MMCM 时钟，默认 **160 MHz**；输入、网络、输出流用异步 FIFO 搬运，状态采用请求/应答握手同步。两路 U-Net AXI 主口经异步 AXI clock converter 回到 80 MHz AXI/DDR 路径；原 HDMI 和图像处理时钟不变。160 MHz 是当前 OOC 路由验证值，整工程实现仍须重新检查时序。

## DDR、片上资源与性能

| 区域 | 起址 | 实际数据 | 保留窗口 |
|---|---:|---:|---:|
| 权重、偏置和头部 | `0x28000000` | 26,501,440 B | 64 MiB |
| 中间特征、输入、类别 | `0x2C000000` | 19,398,656 B | 32 MiB |
| 配准参考/当前帧 | `0x2E000000` | 524,288 B | 512 KiB |

DDR 由权重口和 feature 读写口访问；另有配准 AXI 口。PL 不缓存整张 U-Net 特征图，特征张量仍存于 DDR，片上 cache 用于 tile 内复用。

| 综合/实现层次 | LUT | FF | DSP | BRAM tile |
|---|---:|---:|---:|---:|
| U-Net 核心 OOC 放置布线，160 MHz | 26,646 | 45,187 | 90 | 4 |
| 当前 `top1` RTL 综合预算 | 37,450 / 46,200 | 54,545 | 116 / 160 | 92 / 95 |

U-Net 核心 OOC 160 MHz 报告 WNS **+0.161 ns**、WHS **+0.048 ns**。整顶层预算不包含 Block Design 的 DMA、AXI interconnect、时钟转换器等资源，不能当成完整工程已经通过实现。AXI clock converter 的 FIFO 配置使用 BRAM；当前整机只剩 3 个 tile 的预算，不能据此继续堆大块 BRAM cache。请以新生成的整工程 implementation 报告为最终依据。

模型约 **3,373,326,336 MAC/帧**。按 32 个 MAC/周期、160 MHz 计算，只有乘加的理论下限约 **0.659 秒/帧**，也就是理想上限约 **1.52 FPS**；真实速度还会受 DDR、数据搬运、层间处理影响而更慢。因此此硬件配置达不到 10 FPS 底线。达到 10 FPS 至少需要约 211 个并行 MAC 单元在 160 MHz 连续满载，尚未计任何访存和控制开销，不能靠加 BRAM cache 达成。

## Patient 离线分割缓存

Cardiac patient 的模型分割与后续流分析流程见[医学 patient 缓存说明](../../docs/design/medical_patient_cache.md)。分割完成后，后续流分析读取本地注册灰度、掩膜和轮廓，跳过配准和 U-Net；仍执行医学指标、显示与回传。

## 生成、综合和加载

重新生成 HLS RTL 与权重：

```bash
bash rtl/unet/tools/build.sh
```

完整构建：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f
```

把与 32 路程序 ID 匹配的权重装入 DDR 并运行 PS：

```bash
UNET_WEIGHTS="$(cygpath -w build/unet/model/weights.bin)" bash scripts/flash_current.sh init
```

位流、PS、DDR 权重必须来自同一版本。断电会清除 DDR 权重；加载脚本完成权重校验后才启动 PS。未加载匹配权重时仍可运行图像处理模式，但医学分割会明确拒绝启动。

## 验证状态

已通过：

1. 32 路内核在普通卷积、深度卷积和尾通道场景下完成 Vitis HLS C/RTL 协同仿真：`build/unet/production32_kernel_cosim.log`。
2. 完整模型数值参考对 256×256 样本的 65,536 个类别全部一致，最大 logit 误差 `1.69e-5`：`build/unet/production32_check/verification.json`。这验证实现与现有模型相符，不证明临床精度。
3. 32 路 U-Net 核心 OOC 160 MHz 路由；当前完整顶层 RTL 综合预算；医疗缓存顶层握手/反压、空掩膜无旧值残留、PC 网络协议与 GUI 工作流测试。
4. 主机侧 112 个测试通过，1 个测试因 Windows 禁止创建符号链接而跳过；`freshness.py --check` 和 GUI JavaScript 语法检查通过。

尚未通过或尚未进行：完整模型全网 RTL 仿真、完整 Vivado BD/整工程布线、当前版本上板运行与速度测量。旧位流不支持新的医学缓存协议；修改后必须重新构建硬件和 PS 并烧录，再加载匹配权重。类别与真实解剖标注的对应关系也仍需数据集核验。
