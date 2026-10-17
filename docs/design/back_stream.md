# PL 图像回传接口

已接通 PL 像素回传、AXI DMA S2MM、DDR、PS 网络发送和 PC 显示。单图仍保存文件，流模式只在内存显示。
地址、GUI 使用及失败恢复见 [network_ddr.md](network_ddr.md)。

## 数据路径

```text
double_buf → out_arr ─→ hdmi_out → hdmi_tx
                    └→ back_stream → top1.M_AXIS → AXI DMA S2MM → DDR → TCP → PC
```

`out_arr` 的 `vid_valid` 与 RGB 经过相同两级流水线，只标记 256×256 图像窗口。
`vid_sof` 在换图或显示模式变化后的帧边界产生，普通 HDMI 重复刷新不触发。
`out_arr` 在回传忙时保留重发请求，空闲后的帧边界回传最新显示内容。
`back_stream` 在空闲时接收 SOF，并锁存该帧模式；忙碌时忽略新的 SOF。

## 每个像素一次握手

出口改为 **32 位**，每次 `TVALID && TREADY` 发送一个像素：

| 位段/信号 | 内容 |
| --- | --- |
| TDATA[31:24] | Alpha，固定 255 |
| TDATA[23:16] | B |
| TDATA[15:8] | G |
| TDATA[7:0] | R |
| TKEEP | 固定 0xF，四个字节均有效 |
| TUSER | 仅第一个像素为 1 |
| TLAST | 正常情况下仅第 65,536 个像素为 1，表示整帧结束 |

正常帧长为 **65,536 次握手、262,144 字节**。这与输入的 65,536 字节灰度 BIN 不同。
后续按小端方式读取 DDR 中的字节时，每个像素顺序为 R、G、B、255。
DMA 接收通道应使用 AXI DMA 的包结束语义；这里不是 VDMA 的行尾 TLAST 协议。

## 反压和完成确认

- 源端是持续运行的视频流，没有 ready 输入，回传分支不会暂停 HDMI。
- 输出支持 AXI-Stream 反压：阻塞时保持 TVALID、TDATA、TKEEP、TUSER、TLAST 稳定。
- 默认 FIFO 为 2048 个像素，另外有输出寄存器和一个应急尾拍寄存器。
- 接收完规定数量的源像素后，`back_en` 变为 0；FIFO 中的数据继续发送。
- 最后一拍 `TVALID && TREADY && TLAST` 后，`frame_sent` 拉高一个周期，立即恢复空闲。
- 不包含接收确认输入或等待 ACK 状态；模式在 SOF 锁存到独立 `frame_mode` 输出。
- `frame_sent` 表示 AXI 包传输结束，并不表示 PC 已保存文件。还需结合错误及实际长度判断成功。

有限 FIFO 无法承受无限期反压。若空间耗尽且后续像素将丢失，模块置 `overflow=1`，
停止本次捕获，将已捕获前缀以 TLAST 结束为短包，避免永久挂住接收 DMA。
已向接收端提出的 AXI 拍保持稳定。后续 PS **必须拒绝长度不等于 262,144 字节的包**，
并将失败报告给 PC。错误在下一次空闲接收 SOF 或复位时清除。
下游完全不 ready 时，包的发送会等待，但 HDMI 不受影响。

## 当前顶层接法

所有回传信号属于 **pclk 域**；M_AXIS 的接口属性也绑定 pclk。
DMA 的 S_AXIS_S2MM 当前使用同一 25.2 MHz 时钟；以后若改成不同时钟，需要时钟转换。

旧反馈寄存器 0x30 / 字节偏移 0xC0 及对应 CDC 已删除。
`BACK_FRAME_MODE` 为 0x32 / 字节偏移 0xC8，只读真实回传帧模式。
模式在 SOF 锁存，经两级同步后在 S2MM 完成、busy 清零时读取；不能以像素 Alpha 代替模式。
`BACK_STATUS` 编号 0x31、字节偏移 0xC4；bit0=busy、bit1=0、bit2=overflow，
状态经两级同步送入 clk 域。PS 确认 S2MM 实际长度正确、busy 清零后发送结果。
单图的 SAVED 在 PC 保存后释放 DDR 并回复 DONE；流模式在整帧复制到 TCP 发送缓冲后自动释放。
模式更新通过 TCP RENDER：先准备 S2MM，再写显示模式寄存器，防止无人接收时回传溢出。
`back_busy`、`back_overflow`、`back_frame_sent` 已标记为调试信号。

## 局部验证

```bash
python scripts/tests/run_display_checks.py
```

`tb_back_stream` 检查三张完整帧无需 ACK 连续发送、模式锁存、反压稳定性、帧尾阻塞、复位、
FIFO 溢出短包、容量边界及单像素帧。
`tb_hdmi_out` 核对五帧 HDMI 和三帧 AXI 回传，确认黑边不计入回传、
反压不暂停 HDMI、模式改变重发、忙时延后、未改变时不重复发送。
`tb_display_regs` 检查已移除的 0xC0 返回错误、0xC8 模式只读、AW/W 独立握手和 WSTRB。
