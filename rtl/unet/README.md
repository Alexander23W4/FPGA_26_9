# 完整四腔 U-Net：DDR 推理试验版

此目录实现现有 `smp.Unet(encoder_name="mobilenet_v2", in_channels=1, classes=5)` 的完整推理。未修改 `ip/ai4chamberseger`，也未使用其中 mask/contour 固定为零的 RTL。

## 当前链路

```
AXI 输入 → 输入 xbar
              ├─ 图像处理：denoise → threshold ──────────────┐
              └─ 医学分析：DDR 配准 → u_unet → u_medical ────┤
                                                           ↓
                                                       输出 xbar
                                                           ↓
                                                  hdl_out → double_buf
                                                     ├─ HDMI 着色输出
                                                     └─ 回传着色 → S2MM → DDR → PS/TCP → PC
```

`top1` 默认 `ENABLE_UNET=1`。`ENABLE_UNET=0` 只用于旧显示通路的短仿真，保留旧 BRAM 配准并让分割输入空闲。真正启用网络的顶层另有完整 IP 展开验证。

## 模型保留范围

- 从同事 ZIP 中的浮点头文件恢复全部 312 组有效参数；62 个 BatchNorm 训练计数器不参与 eval 推理。
- 78 个操作：普通/逐点卷积、深度卷积、ReLU6、线性投影、残差相加、最近邻上采样、跳跃连接拼接、解码器 ReLU、最终五类分数。
- 计算保持 FP32。BatchNorm 按 eval 公式折叠到卷积权重/偏置，epsilon 为 `1e-5`。这保持原数学模型，不沿用同事的统一乘 128 截断转换。
- 输入严格为 256×256×8-bit，按 `pixel/255` 归一化。输入已由 `u_registration` 配准；输出灰度与这张配准图一致。
- 最终按五类分数 argmax，整数类别直接进入三行缓存，生成四路 one-hot mask，再通过四邻域生成各腔室的内轮廓。DDR 仍保存浮点类别用于调试；像素输出不再从这份副本重新读取并转换类别。
- 没有 `.pth` 可用于额外核验；使用的是同事导出的六位小数浮点权重，不能宣称与未提供的原始 checkpoint 逐位相同。

架构依据可核对 [SMP MobileNet 编码器](https://github.com/qubvel-org/segmentation_models.pytorch/blob/v0.3.4/segmentation_models_pytorch/encoders/mobilenet.py)、[SMP U-Net 解码器](https://github.com/qubvel-org/segmentation_models.pytorch/blob/v0.3.4/segmentation_models_pytorch/decoders/unet/decoder.py)、[Torchvision MobileNetV2](https://github.com/pytorch/vision/blob/v0.17.2/torchvision/models/mobilenetv2.py)。导出器逐项核对数组名称、形状和全部参数消费情况，不默默丢弃网络层。

## 接口与编号

`unet.v` 提供要求的 `in_data/in_valid/in_ready/in_eof`、`out_data/out_valid/out_ready/out_eof`、四路 mask/contour。另外有 `enable`、状态输出和两个 DDR AXI 主口。

输入/输出只在 valid 与 ready 同时有效时推进。每帧完整输出 65,536 个像素，包括背景。下游停顿时灰度、八个标记和 EOF 一起保持。网络分帧接收、计算、输出，不能把它理解成收到一个像素马上推理出这个像素。

类别编号暂按用户选择沿用同事代码：背景 0、LA 1、RA 2、LV 3、RV 4；尚未据训练标注确认解剖学对应关系。`top1.UNET_CLASS_MAP=16'h4321`，从低到高四个 nibble 对应 LA/RA/LV/RV 的类别 ID。若确认训练使用 `1=LV,2=LA,3=RA,4=RV`，可改为 `16'h4132`，无需改变网络或重新训练，但需要重新生成位流。

## DDR 和片上资源

| 区域 | 起址 | 本版本实际大小 | 保留窗口 |
|---|---|---:|---:|
| 网络权重、折叠偏置及头部 | `0x28000000` | 26,457,792 B | 64 MiB |
| 中间特征、输入和类别结果 | `0x2C000000` | 19,398,656 B | 32 MiB |
| 配准前/当前原帧 | `0x2E000000` | 524,288 B | 512 KiB |

避开了原图缓冲 `0x20000000`、回传缓冲和 `0x21000000` 附近的连续流 DDR 环。

计算核心使用 16 路并行 FP32 乘加、64 像素空间 tile、16 输入通道 tile。权重在空间 tile 内复用，输入在输出通道间复用；中间特征根据生命周期复用 DDR 地址，并保留解码器需要的跳跃连接。

片上完整配准双帧会使工程 BRAM 超过 Z-7015 总量。因此启用网络时，配准改用 `rtl/inter_fr/ddr`：全帧进 DDR，仅 48×48 参考 ROI 与 64×64 当前 ROI 留片上，保持 ±8 SAD、相同平局规则、相对本序列首帧的位移和越界补零。每次重新进入医学模式增加 epoch，下一帧重建参考。

| 独立 HLS 估计，非整工程实现结果 | DSP | LUT | BRAM_18K | 估计最长周期 |
|---|---:|---:|---:|---:|
| 完整 U-Net 核心（64 像素 tile、直接类别行缓存） | 98 | 28,475 | 13 | 9.125 ns |
| DDR 配准核心 | 4 | 3,864 | 8 | 9.125 ns |

目标处理时钟是 80 MHz；卷积 MAC 循环达到 II=1。上述不包含所有显示、阈值、互连和医学统计资源。最终容量、时序必须以用户运行的整工程 Vivado 实现为准。

三个新 32-bit AXI4 主口通过原 HP0 互连的 S02/S03/S04 接入 64-bit HP0。宽度转换由互连实现，按 32-bit 地址和 WSTRB 传递全部数据；不改变原 VDMA/S2MM 配置，也没有丢弃半个数据字。

### 整工程 BRAM 与调试核

完整原模型的实际优化后网表使用 115 个 RAMB36 和 9 个 RAMB18，合计 119.5 个 BRAM tile，超过器件的 95 个。层级报告定位：双帧缓存 68、Otsu 帧缓存 16、DDR 配准 3、U-Net 1.5、两个 ILA 调试核 27.5，其余功能 3.5（均按 RAMB36 等效计）。

普通构建现在默认通过 `scripts/tcl/debug_budget.tcl` 移除历史 HDMI、AXI-Lite、VDMA 采集 ILA，同时迁移已有 BD；功能逻辑按原网表计为 **92/95 BRAM tile**。完整模型、权重、HDMI 与回传数据路径保持原样。关闭 ILA 后无法使用这些探针抓波形，串口/网络状态读取仍可用。

`FPGA_DEBUG_ILA=1` 可显式保留已有调试核，用于另行控制资源的调试配置；当前完整模型工程不能直接恢复原深度的两个 ILA，否则会再次超容量。

### 性能边界

该完整模型每帧 **3,373,326,336 MAC**。按 16 路、80 MHz 算，只有算术的理想下限也约为 **2.64 秒/帧**；DDR、缓存装填、层间操作还会增加耗时。因此本版用于保留完整模型并验证硬件路径，不具有 100 FPS 能力。提高时钟或并行度不能无视这块器件的资源容量。需要高帧率时，应在此正确基线之上进行量化、缓存调度优化，并重新评估是否需要缩小/重训模型。

## 构建和加载

已生成的 Verilog 位于 `generated/`，配准 Verilog 位于 `rtl/inter_fr/ddr/generated/`。浮点算子的 Vivado 创建脚本随 RTL 一起提供；普通构建会自动生成这些标准算子 IP、接入 DDR，并验证源文件指纹。

完整模型文件在本机 `build/unet/model/weights.bin`。若换电脑或修改模型/HLS 源码，在仓库根目录 Git Bash 中重新生成：

```bash
bash rtl/unet/tools/build.sh
```

随后使用原有完整构建命令：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f
```

烧录位流、ELF，并将匹配的模型加载 DDR：

```bash
UNET_WEIGHTS="$(cygpath -w build/unet/model/weights.bin)" bash scripts/flash_current.sh init
```

加载脚本在 CPU 启动前写入完整文件，最后才提交模型 magic。核心检查版本、操作数、workspace 大小、并行度、分辨率、程序 ID；不匹配时不接收图像。断电后 DDR 权重消失，需要重新加载。常规不带 `UNET_WEIGHTS` 的烧录仍可使用图像处理模式，但不能直接开始医学分割。

新增只读 `UNET_STATUS`，字索引 `0x2A`，AXI 字节地址 `0xA8`：bit0 模型已就绪，bit1 正在计算，bit2 输入帧格式错误。PS 在医学任务开始前检查就绪位，缺模型时直接返回错误，不让 DMA 无期限等待。医学任务超时扩为 300 秒，图像处理仍用原期限。

## 已验证与未验证

已完成：

1. 完整 HLS 算法 C 模型与独立 NumPy **原始浮点参数 + 未折叠 BN** 解释器对比：真实 Cardiac 256×256 输入的全部 65,536 个类别一致；最大分数误差约 `1.86e-5`；原灰度、四路 mask、二维 contour 均一致。
2. 共享 16 路 MAC 的普通/深度卷积 **实际 Verilog C/RTL 联合仿真通过**，覆盖 stride、padding、输出通道尾块。
3. DDR 配准 **实际 Verilog C/RTL 联合仿真通过**，覆盖九张完整帧、`(+2,-1)`、`(+4,-2)`、epoch 重建参考、反复 ±6 位移不累积漂移和 EOF。
4. 启用完整网络的真实 `top1` 含浮点 IP 编译/展开通过；独立 BD 地址、时钟、复位、HP0 宽度和原 DMA 连接验证通过。
5. PS 原始 C 网络状态机测试和 GUI/网络测试；原显示路径局部回归。

新版本尚未进行：整张网络所有计算的完整 RTL 仿真、新版整工程实现和新版上板性能验证。旧版已测单帧 27.74 秒，其中 PL→DDR 27.71 秒，PC 收图约 4.4 ms；DDR logits/类别与独立软件参考一致，但最终回传仅 49 个黄色像素，分类之后存在异常。新版去掉类别 DDR 往返读取并通过完整尺寸输出 RTL 仿真，仍需上板确认是否消除该异常。详见 `docs/design/medical_debug_2026-10-26.md`。样本类别一致说明实现对应现有模型，不等于模型已具备医学准确性。

本地重跑完整数值对比：

```bash
python rtl/unet/tools/check_model.py --frame "你的256x256.bin"
```

验证报告和日志在 `build/unet/`：`verification.json`、`kernel_cosim.log`、`registration_cosim.log`、`bd_validate_final.log`、`display_regression.log`。`source_fingerprint.json` 防止修改 HLS 或权重后继续综合旧 RTL；Python 缓存文件不计入 PL 源码指纹。
