# FPGA_26：Zynq 灰度图像去噪与 HDMI 显示

本项目面向“基于 FPGA 的医学影像实时分析与智能辅助展示”竞赛方向，使用小梅哥 ACZ7015 开发板，搭建从图像存储、DDR 搬运、硬件去噪到 HDMI 显示的数据通路。

当前代码处理 **256×256、8 位灰度图像**：ARM 端负责图片管理和传输控制，FPGA 端负责去噪、帧缓存和视频输出。医学影像智能分析是后续扩展方向，当前尚未实现病灶识别、模型推理或分割结果叠加。

> 本文按当前源码整理。模块已有实现不代表已经通过完整上板验证；实际功能、时序和性能需要结合仿真、实现报告及硬件测试确认。

## 数据通路

```text
电脑上的灰度 .bin 文件
    │ USB 串口 / PowerShell 脚本
    ▼
PS / ARM：接收数据、CRC32 校验、管理图片目录
    │
    ▼
板载 eMMC ──读取──► PS DDR
                       │ AXI VDMA MM2S，经 PS S_AXI_HP0 读取
                       ▼
                 AXI4-Stream（32 位）
                       │ axi2px：拆成 8 位像素，生成帧边界
                       ▼
                 denose：HLS 去噪模块
                       │
                       ▼
                 hdl_out → 双 BRAM 帧缓存
                                  │
                                  ▼
                 hdmi_out：640×480 视频时序
                                  │
                                  ▼
                 hdmi_tx：TMDS 编码、OSERDESE2 串行化
                                  │ OBUFDS 差分输出
                                  ▼
                          HDMI_2（J7）显示器
```

PS 通过 AXI-Lite 配置 VDMA。PL 自定义控制寄存器接口也已接入，但模式、命令和调试寄存器的内部逻辑仍需补全。

当前主链路使用 **eMMC 裸块存储**。早期 SD 卡 SPI 输入方案，以及处理结果经 VDMA S2MM 回写 DDR、通过网口回传的方案，均不属于当前主链路。

## 当前实现

| 部分 | 内容 |
| --- | --- |
| 图片上传 | 通过串口接收图片，执行 CRC32 校验，写入 eMMC 后读回比对 |
| 图片目录 | 自定义 TOC，最多登记 8 张图片，记录名称、尺寸、数据位置和 CRC |
| DDR 搬运 | 将指定图片载入 DDR，维护 CPU cache 一致性，再配置 VDMA |
| 像素拆分 | 将每个 32 位 AXI-Stream 数据拍拆成 4 个 8 位灰度像素，支持下游反压 |
| 去噪 | 接入 Vitis HLS 2023.2 生成的 `denose` RTL，设计采用 3×3 高斯平滑 |
| 帧缓存 | 两块 256×256×8 bit BRAM，共 128 KiB；协调处理端写入和显示端读取 |
| 视频显示 | 640×480、60 Hz 时序；256×256 图像居中显示，外围填黑，灰度复制到 RGB 三通道 |
| HDMI 输出 | TMDS 编码、10:1 串行化和差分输出均已有代码 |
| 工程工具 | Tcl 生成 Vivado 工程及 Block Design，脚本构建位流、XSA 和 ARM 应用 |

60 Hz 是视频输出时序，**不等同于去噪算法每秒处理 60 张新图**。没有新帧可切换时，显示端继续读取当前帧。

## 硬件与工具

| 项目 | 配置 |
| --- | --- |
| 开发板 | 小梅哥 ACZ7015 |
| FPGA | `xc7z015clg485-2`（Zynq-7015） |
| DDR3 | 1 GB，32 位总线 |
| 板载输入时钟 | 50 MHz |
| 当前 PL / 像素时钟 | 25.2 MHz，由 Clocking Wizard 产生 |
| HDMI 串行时钟 | 126 MHz，与像素时钟同源 |
| 视频接口 | HDMI_2（J7），FPGA 原生 TMDS |
| 串口 | PS UART1，115200 波特，8N1；PC 脚本默认 `COM7` |
| 工具链 | Vivado / Vitis 2023.2，Windows、Git Bash、PowerShell |

HDMI_1（J6）使用 SIL9022A，与当前输出路径不同。连接显示器时使用 HDMI_2；电脑普通 HDMI 输出口不能直接作为视频输入。

板级配置位于 `board/acz7015/`，引脚约束位于 `constrs/acz7015/acz7015.xdc`。

## 目录与主要模块

```text
rtl/                       FPGA Verilog 源码
  top1.v                   PL 顶层，连接处理与显示链路
  axi2px.v                 AXI-Stream 转灰度像素流
  axi_lite_rcv.v           PS 控制寄存器接口
  denose*.v                HLS 生成的去噪模块与内部 RAM
  hdl_out.v                处理结果写入及帧缓存切换协调
  double_buf.v             两块 BRAM 帧缓存
  hdmi_out.v               视频时序、图像窗口和缓存读取
  hdmi_tx.v                TMDS 编码及串行化
csrc/MID_plt/src/          ARM 裸机应用
  main.c / app.c           初始化、串口命令及测试分发
  drv_emmc.c / drv_vdma.c  eMMC 与 VDMA 驱动
  img_catalog.c           图片目录管理
  img_ddr.c               DDR 缓冲及 cache 维护
  feat_*.c                上传、清空、载入 DDR 等功能
  pl_ctrl_test.c          三图轮换测试
scripts/
  build.sh                构建入口（Git Bash）
  tcl/                    建工程、实现、导出及 JTAG 下载
  vitis/                  Vitis 平台和应用构建
  pc/                     PC 端串口操作脚本（PowerShell）
board/acz7015/            板卡文件、PS7 预设及驱动资料
constrs/acz7015/          引脚约束
docs/                    需求、设计记录和环境排查文档
sim/tb/                  仿真测试平台预留目录，目前只有占位文件
bd/、ip/                 预留目录
build/                   生成的工程、构建日志与归档产物
```

ARM 源码采用 `.c` 文件平铺、头文件按功能分目录的方式，以适配当前 Vitis 构建流程。

## 构建与下载

以下构建命令在仓库根目录的 **Git Bash** 中执行。

### 1. 检查环境

```bash
./scripts/build.sh check
```

脚本默认从 `E:/Xilinx` 查找 2023.2 工具链。安装位置不同时，在当前 Git Bash 会话中设置：

```bash
export XILINX_ROOT=/d/Xilinx
export VIVADO_VER=2023.2
```

### 2. 构建 Zynq 硬件

```bash
./scripts/build.sh zynq -n fpga_26 -H
```

`-H` 启用当前显示链路所需的 HP0、VDMA 和 PL 连接。修改 Block Design 生成脚本后，需要重新生成工程：

```bash
./scripts/build.sh zynq -n fpga_26 -H -R
```

`-R` 会删除并重建 `build/vivado/fpga_26/`。如有尚未保存到源码或 Tcl 的 GUI 修改，应先导出：

```bash
./scripts/build.sh export -n fpga_26
```

### 3. 构建 ARM 应用

```bash
./scripts/build.sh app -n MID_plt -p fpga_26 -f
```

应用名为 `MID_plt`，平台名为 `fpga_26`，二者必须不同。`-f` 强制重建平台，适用于硬件 XSA 更新后；仅修改 C 源码时可省略。

脚本会从 `build/out/` 选择按路径排序最后的 XSA。构建前检查日志中的 `Using hardware platform`，确保它来自本次硬件工程。

生成的 Vivado 工程位于 `build/vivado/fpga_26/`，Vitis 工作区位于 `csrc/`。位流、XSA、ELF 按构建步骤归档到 `build/out/<时间戳>_<git版本>/`，并附日志与 `MANIFEST.txt`。

### 4. 通过 JTAG 下载并运行

连接开发板电源和 JTAG，在 Git Bash 中调用：

```bash
# 替换为本次硬件构建实际生成的 .bit 路径
BIT="build/out/<本次硬件构建目录>/system_wrapper.bit"
ELF="csrc/MID_plt/build/MID_plt.elf"
PS_INIT="csrc/fpga_26/hw/sdt/ps7_init.tcl"

"${XILINX_ROOT:-/e/Xilinx}/Vitis/${VIVADO_VER:-2023.2}/bin/xsct.bat" \
  "$(cygpath -w scripts/tcl/flash_all.tcl)" \
  "$(cygpath -w "$BIT")" \
  "$(cygpath -w "$ELF")" \
  "$(cygpath -w "$PS_INIT")" init
```

核对 ELF 和 `ps7_init.tcl` 的实际生成位置，并使用同一硬件版本对应的文件。该脚本初始化 PS、配置 PL 并运行 ARM 应用；这是 JTAG 下载流程，不是掉电后自动启动的启动镜像制作流程。

## 上传和显示图片

### 图片格式

当前 PL 固定按以下格式处理：

- 宽 256、高 256，按行排列。
- 每个像素 1 字节，取值 0～255。
- 文件为无文件头的原始灰度数据，总长度 **65,536 字节**。

PNG、JPEG、DICOM 等文件需先解码、调整尺寸并导出灰度原始数据。上传脚本允许填写其他尺寸，但当前 PL 并不自动适配其他分辨率。

### PC 端操作

以下命令在仓库根目录的 **PowerShell** 中执行。将 `COM7` 替换为开发板实际串口，运行脚本前关闭占用该串口的终端。

```powershell
# 上传图片，默认由板端分配存储位置
powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_add.ps1 -File D:\test_img\iceberg.bin -Port COM7 -Width 256 -Height 256 -Bpp 1

# 列出板上图片
powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_list.ps1 -Port COM7

# 选择第 0 张图片，载入 DDR 并启动 VDMA
powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_to_ddr.ps1 -Index 0 -Port COM7
```

索引从 0 开始。载入命令的日志会检查 CRC、VDMA 寄存器、复位、错误位和运行状态；这些检查不能代替对去噪结果和 HDMI 画面的验证。

需要删除所有已登记图片并重置目录时，执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_clear.ps1 -Port COM7
```

### 串口命令

| 命令 | 作用 |
| --- | --- |
| `?` | 打印帮助 |
| `I` | 列出图片目录 |
| `A` | 上传图片；后续二进制协议由 `emmc_add.ps1` 处理 |
| `D` | 载入图片并启动 VDMA，后跟 4 字节小端图片索引 |
| `E` | 清除已登记图片并重置目录 |
| `-pl_ctrl_test` 加换行 | 进入三张图片轮换测试 |

三图测试按 `pl_ctrl_test.c` 中配置的名称寻找 `iceberg`、`lofoten`、`gb200`，需预先上传对应图片。测试循环间隔约 10 秒：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\pc\run_test.ps1 -Test pl_ctrl_test -Port COM7
```

停止 PC 脚本不会停止 ARM 上的无限循环；要恢复普通命令交互，需重启板端应用。

## 存储与地址约定

| 项目 | 当前值 |
| --- | --- |
| eMMC 块大小 | 512 字节 |
| 图片目录 TOC | 第 1024 块 |
| 图片数据起点 | 第 2048 块 |
| 图片目录容量 | 最多 8 张 |
| 普通 `D` 命令的 DDR 缓冲 | `0x20000000`，预留 16 MiB |
| 三图测试的 DDR 缓冲 | `0x10000000` |
| VDMA 寄存器基地址 | `0x43000000` |
| PL 控制寄存器基地址 | `0x44000000` |

对应定义分布在 `csrc/MID_plt/src/app/cfg.h`、`csrc/MID_plt/src/config/pl_cmd.h` 和 Block Design 生成脚本中，修改时需保持一致。eMMC 使用项目自定义裸块布局，不依赖 FAT 文件系统。

## 当前限制与后续工作

- **控制逻辑待补全**：`top1.v` 中模式、命令和数据寄存器没有接入更新逻辑，调试寄存器输入也未完整驱动，不能据此宣称模式切换或参数配置已可用。
- **验证资料待补齐**：`sim/tb/` 目前只有占位文件；需补像素拆分、去噪、帧切换和视频输出的测试平台及参考结果比对。
- **HLS 源码待纳入仓库**：当前包含生成的去噪 Verilog，尚未找到对应 HLS C++ 源码及完整复现工程。
- **性能需要实测**：需记录处理吞吐、端到端延迟、资源占用和实现后时序，不能将 HDMI 刷新率直接当作算法处理帧率。
- **医学分析功能待扩展**：尚未实现医学文件解析、模型推理、病灶分割、结果叠加或图形操作界面。

## 更多资料

- 构建脚本说明：`scripts/README.md`
- ARM 源码组织：`csrc/MID_plt/src/README.md`
- 开发流程：`docs/开发流程.md`
- 选题与评分要求：`docs/design/requirement.md`
- 硬件核对：`docs/env/硬件核对表.md`
- 环境配置：`docs/env/环境搭建指南.md`

部分设计笔记和脚本注释保留了历史方案；接口和命令应以当前实现为准。

## 许可证

本项目采用 MIT License，详见 `LICENSE`。医学影像相关内容用于工程教学与算法演示，不作为临床诊断依据。
