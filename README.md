# FPGA Medical Image Display Demo

这是一个面向 FPGA 学习和工程演示的医学影像处理项目。当前实现了一条简化的数据通路：

```text
SD 卡 SPI 输入 -> 8-bit 灰度归一化 -> 640x480 视频时序 -> TMDS 编码 -> HDMI
```

## 当前功能

- 通过 SPI 模式读取 SD 卡上的连续 8-bit 灰度数据；
- 对输入像素进行黑电平和白电平归一化；
- 生成 640x480@60Hz 视频时序；
- 将灰度图像复制到 RGB 三个通道，形成黑白显示；
- 生成 HDMI TMDS 10-bit 符号，供外部高速串行器使用；
- 按功能拆分为多个独立的 SystemVerilog 模块。

## 目录结构

```text
.
├── rtl/                         FPGA 源码（SystemVerilog）
│   ├── top/          sd_hdmi_gray_top.sv     顶层模块
│   ├── video/        hdmi_video_640x480.sv   视频时序
│   │                 tmds_encoder.sv         TMDS 编码
│   ├── storage/      sd_spi_stream.sv        SD 卡 SPI 字节流接收
│   ├── imgproc/      gray_normalize.sv       灰度归一化
│   └── common/       sync_fifo.sv            通用同步 FIFO
│
├── sim/                         仿真
│   └── tb/                       测试平台
│
├── constrs/                     约束
│   └── acz7015/      acz7015.xdc   板级引脚模板
│                     pinmap.csv    引脚速查表
│
├── board/                       板级支持包（不随项目变）
│   └── acz7015/      ps7_preset.tcl   PS7 一键配置
│                     board_files/     Vivado Board File
│                     drivers/         板载串口驱动
│
├── sw/                          PS 端软件
│   ├── baremetal/               裸机
│   ├── linux/                   Linux 应用
│   └── include/                 公共头文件
│
├── scripts/                     构建与自动化（详见 scripts/README.md）
│   ├── build.sh                 唯一入口 ★
│   ├── env_check.sh             环境自检
│   └── tcl/  xsct/              执行层
│
├── docs/                        文档（详见 docs/README.md）
│   ├── design/                  项目设计文档
│   ├── reference/               参考资料
│   └── env/                     环境与硬件事实库
│
├── bd/  ip/                     预留：Block Design Tcl / 自定义 IP
├── build/                       生成物（git 忽略）
└── LICENSE
```

## 顶层模块

顶层模块名为 `sd_hdmi_gray_top`，主要接口如下：

- `clk_pixel`：像素时钟，640x480@60Hz 建议约为 25.175 MHz；
- `clk_5x`：预留给外部 10:1 HDMI 串行器；
- `rst_n`：低有效复位；
- `start`：启动 SD 卡 SPI 数据接收；
- `sd_sck`、`sd_cs_n`、`sd_mosi`、`sd_miso`：SD 卡 SPI 接口；
- `hdmi_tmds_data`：三个颜色通道的 10-bit TMDS 符号；
- `hdmi_tmds_clock`：TMDS 时钟符号；
- `hdmi_hsync`、`hdmi_vsync`、`hdmi_de`：视频控制信号。

## 目标板：小梅哥 ACZ7015（Zynq-7015）

| 项目 | 值 |
|---|---|
| 器件 | `xc7z015clg485-2` |
| 系统时钟 | **L5**，50 MHz |
| DDR3 | 1 GB，32 位，1.35V，DDR3-1066 |
| **HDMI_2 (J7)** | **FGPA 原生 TMDS**：数据 `N6 / M8 / K7`，时钟 `T2` ← 本项目走这条 |
| HDMI_1 (J6) | 经 SIL9022A，FPGA 侧是并行 RGB |

> ⚠️ 本项目输出 10-bit TMDS 符号，对应的是 **HDMI_2 (J7)**，不是 HDMI_1。
> 板上**没有外部 10:1 串行器**，需用 7 系列 **OSERDESE2**（5:1 DDR = 总计 10:1）。
> 详见 `docs/env/硬件核对表.md` 第 8 节。

## 构建

**入口只有 `./scripts/build.sh`（需要 Git Bash）**

```bash
./scripts/build.sh check                          # 环境自检

./scripts/build.sh pl   -n led_demo -t sd_hdmi_gray_top   # 纯 PL 全流程
./scripts/build.sh zynq -n zynq_led -a                    # Zynq 流程（带 AXI）
./scripts/build.sh sim  -n sd_hdmi -b tb_video            # 仿真
```

产物自动归档到 `build/out/<时间戳>_<githash>/`，含位流、日志和 `MANIFEST.txt`。

> 工程目录 `build/` 不入库 —— 每次由脚本重建。
> 需要 GUI 时先建出来再打开：`vivado build/vivado/<工程名>/<工程名>.xpr`
> 在 GUI 里改完后跑 `./scripts/build.sh export -n <工程名>` 把改动导回 Tcl 提交。

详细说明见 `scripts/README.md`。

## 使用说明

将 `rtl/` 下的 `.sv` 文件全部加入 FPGA 工程，并将 `sd_hdmi_gray_top` 设置为顶层模块。然后根据目标 FPGA 开发板补充：

1. 时钟生成与 PLL/MMCM 配置；
2. SD 卡和 HDMI 的引脚约束；
3. FPGA 厂商对应的 OSERDES 或高速串行输出原语；
4. HDMI 差分输出缓冲；
5. SD 卡初始化、命令发送和图像文件读取逻辑。


## 当前简化假设

本项目代码用于教学和算法链路演示，并不是完整的 SD 卡文件系统或 HDMI PHY 实现：

- SD 卡已经处于 SPI 模式，并能够连续提供图像字节流；
- 输入数据按行优先排列，每个像素占 1 个字节；
- SD 卡初始化和扇区选择由外部逻辑或后续模块完成；
- TMDS 10:1 串行化和 HDMI 物理层输出由目标 FPGA 平台实现；
- 当前视频模块没有 DDR 帧缓存，输入吞吐率需要与显示时序匹配。

## 后续扩展

- 增加 SD 卡初始化和 FAT 文件读取；
- 增加 DDR 帧缓存和跨时钟域处理；
- 增加伪彩色、滤波、阈值分割和形态学处理；
- 增加医学图像分割模型和 FPGA 推理加速；
- 增加图像信息、帧率、延迟和分割结果的 HDMI 叠加显示。

## 许可证

本项目采用 MIT License，具体内容见 [LICENSE](LICENSE)。项目中的医学影像相关内容仅用于工程教学与算法演示，不作为临床诊断依据。
