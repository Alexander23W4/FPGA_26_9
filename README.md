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
├── src/
│   ├── sd_hdmi_gray_top.sv     # 顶层模块
│   ├── sd_spi_stream.sv         # SD 卡 SPI 字节流接收
│   ├── gray_normalize.sv        # 灰度归一化
│   ├── hdmi_video_640x480.sv    # VGA/HDMI 视频时序
│   └── tmds_encoder.sv          # TMDS 编码
├── texts/
│   ├── prompt.md                # 医学影像方向基础与拓展要求
│   └── requirement.md           # FPGA 竞赛选题与评分要求
├── LICENSE                      # MIT License
└── README.md
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

## 使用说明

将 `src/` 下的 5 个 `.sv` 文件全部加入 FPGA 工程，并将 `sd_hdmi_gray_top` 设置为顶层模块。然后根据目标 FPGA 开发板补充：

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
