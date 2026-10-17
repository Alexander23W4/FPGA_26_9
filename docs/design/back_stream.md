# PL 图像回传接口

已接通 PL 像素回传、AXI DMA S2MM、DDR、PS 网络发送和 PC 显示。单图仍保存文件，流模式只在内存显示。
地址、GUI 使用及失败恢复见 [network_ddr.md](network_ddr.md)。

## 数据路径

```text
double_buf HDMI 读口(pclk) → out_arr       → hdmi_out → hdmi_tx
double_buf 回传读口(clk)  → out_arr(独立) → back_stream → M_AXIS → S2MM → DDR → TCP → PC
                         ↑ back_reader 连续地址读取，独立于 HDMI 扫描
```

两路各自锁存本帧模式、透明度，RGB 与有效标记经过相同的两级计算。
HDMI 路仍在显示帧边界切换缓存及参数。回传路由 `back_reader` 检测完整新帧，
立即从地址 0 连续读到 65535，不等待 HDMI 帧边界、不插入扫描空白。
模式变化可重绘最近的完整帧；忙碌期间的变化在当前包发完后处理，包中途不换图或换参数。
透明度单独变化在下一次图像任务生效，沿用 GUI 原有重传逻辑。

每块 bank 使用真双口 BRAM：pclk 口只供 HDMI；clk 口由写端和回传读端分时使用。
写端与回传端必须拥有不同 bank，因此无需复制整套帧缓存。
写端只有在 HDMI 已接管刚完成的 bank，且回传端也离开另一 bank 后，才会复用另一 bank。
所以两块缓存仍保留 HDMI 换帧造成的写端节流，不代表处理吞吐已经完全独立于 HDMI。

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

- 回传读请求由 `source_ready` 控制，源地址只在实际发起读取时递增。
- 输出支持 AXI-Stream 反压：阻塞时保持 TVALID、TDATA、TKEEP、TUSER、TLAST 稳定。
- 顶层回传 FIFO 为 32 个像素，预留 8 个位置容纳 RAM 和颜色计算中已在途的像素。
- 接收完规定数量的源像素后，`back_en` 变为 0；FIFO 中的数据继续发送。
- 最后一拍 `TVALID && TREADY && TLAST` 后，`frame_sent` 拉高一个周期，立即恢复空闲。
- 不包含接收确认输入或等待 ACK 状态；模式在 SOF 锁存到独立 `frame_mode` 输出。
- `frame_sent` 表示 AXI 包传输结束，并不表示 PC 已保存文件。还需结合错误及实际长度判断成功。

S2MM 长期不接收时，FIFO 接近满就停止新读请求，已在途像素仍可安全入队。
恢复后从原位置继续，正常独立读路径不会因长期反压而丢像素。
若错误连接使源端忽略读请求节流、导致空间耗尽，仍保留防御性错误处理：置 `overflow=1`，
停止本次捕获，将已捕获前缀以 TLAST 结束为短包。
已向接收端提出的 AXI 拍保持稳定。后续 PS **必须拒绝长度不等于 262,144 字节的包**，
并将失败报告给 PC。错误在下一次空闲接收 SOF 或复位时清除。
下游完全不 ready 时，包的发送会等待，但 HDMI 不受影响。

## 当前顶层接法

所有独立回传信号属于 **clk 域**；M_AXIS 的接口属性绑定 clk。
DMA 的 S_AXIS_S2MM 当前使用同一 25.2 MHz 时钟；以后若改成不同时钟，需要时钟转换。

旧反馈寄存器 0x30 / 字节偏移 0xC0 及对应 CDC 已删除。
`BACK_FRAME_MODE` 为 0x32 / 字节偏移 0xC8，只读真实回传帧模式。
模式在 SOF 锁存，经顶层两级寄存后在 S2MM 完成、busy 清零时读取；不能以像素 Alpha 代替模式。
`BACK_STATUS` 编号 0x31、字节偏移 0xC4；bit0=busy、bit1=0、bit2=overflow，
状态经两级寄存送入 AXI-Lite。PS 确认 S2MM 实际长度正确、busy 清零后发送结果。
单图的 SAVED 在 PC 保存后释放 DDR 并回复 DONE；流模式在整帧复制到 TCP 发送缓冲后自动释放。
模式更新通过 TCP RENDER：先准备 S2MM，再写显示模式寄存器。
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
`tb_independent_return` 覆盖两读口同时访问、不同 clk/pclk、五种颜色模式、模式中途更新、
长时间及间歇 S2MM 反压、缓存复用保护和计时周期。无反压回传不等 HDMI 图像窗口。

计时寄存器及 GUI 实测方法见 [stream_latency.md](stream_latency.md)。
