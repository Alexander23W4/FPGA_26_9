# PL 图像回传接口

已接通 PL 像素回传、AXI DMA S2MM、DDR、PS 网络发送和 PC 文件保存确认。
地址、GUI 使用及失败恢复见 [network_ddr.md](network_ddr.md)。

## 数据路径

```text
double_buf → out_arr ─→ hdmi_out → hdmi_tx
                    └→ back_stream → top1.M_AXIS → AXI DMA S2MM → DDR → TCP → PC
```

`out_arr` 的 `vid_valid` 与 RGB 经过相同两级流水线，只标记 256×256 图像窗口。
`vid_sof` 在切到新图片后产生一次，普通 HDMI 重复刷新或仅切换显示模式不会重新触发。
`back_stream` 在空闲时接收 SOF，并锁存该帧模式；忙碌时忽略新的 SOF。

## 每个像素一次握手

出口改为 **32 位**，每次 `TVALID && TREADY` 发送一个像素：

| 位段/信号 | 内容 |
| --- | --- |
| TDATA[31:24] | 锁存的显示模式，0～4 |
| TDATA[23:16] | R |
| TDATA[15:8] | G |
| TDATA[7:0] | B |
| TKEEP | 固定 0xF，四个字节均有效 |
| TUSER | 仅第一个像素为 1 |
| TLAST | 正常情况下仅第 65,536 个像素为 1，表示整帧结束 |

正常帧长为 **65,536 次握手、262,144 字节**。这与输入的 65,536 字节灰度 BIN 不同。
后续按小端方式读取 DDR 中的字节时，每个像素顺序为 B、G、R、模式。
DMA 接收通道应使用 AXI DMA 的包结束语义；这里不是 VDMA 的行尾 TLAST 协议。

## 反压和完成确认

- 源端是持续运行的视频流，没有 ready 输入，回传分支不会暂停 HDMI。
- 输出支持 AXI-Stream 反压：阻塞时保持 TVALID、TDATA、TKEEP、TUSER、TLAST 稳定。
- 默认 FIFO 为 2048 个像素，另外有输出寄存器和一个应急尾拍寄存器。
- 接收完规定数量的源像素后，`back_en` 变为 0；FIFO 中的数据继续发送。
- 最后一拍握手后，`frame_sent` 拉高一个周期，然后进入 `waiting_ack`，`busy` 保持为 1。
- `back_receive_done` 在当前时钟域拉高一个周期后恢复空闲；提前 ACK 不会截断正在传输的帧。
- `frame_sent` 表示 AXI 包传输结束，并不表示 PC 已保存文件。还需结合错误及实际长度判断成功。

有限 FIFO 无法承受无限期反压。若空间耗尽且后续像素将丢失，模块置 `overflow=1`，
停止本次捕获，将已捕获前缀以 TLAST 结束为短包，避免永久挂住接收 DMA。
已向接收端提出的 AXI 拍保持稳定。后续 PS **必须拒绝长度不等于 262,144 字节的包**，
并将失败报告给 PC。错误在下一次空闲接收 SOF 或复位时清除。
下游完全不 ready 时，包和确认过程都会等待，但 HDMI 不受影响。

## 当前顶层接法

所有回传信号属于 **pclk 域**；M_AXIS 的接口属性也绑定 pclk。
DMA 的 S_AXIS_S2MM 当前使用同一 25.2 MHz 时钟；以后若改成不同时钟，需要时钟转换。

反馈寄存器已接通：`BACK_RECEIVE` 编号 **0x30**，实际字节偏移 **0xC0**，
PS 地址 **0x440000C0**。有效低字节写入 bit0=1 触发一次确认；
写 0、屏蔽低字节的 WSTRB 写入均不会触发。寄存器自动清零，读回始终为 0。

```c
Xil_Out32(PL_REG_ADDRESS(BACK_RECEIVE), 1u);
dsb();
```

不要使用要求“写入值必须等于读回值”的 `pl_write_checked()` 辅助函数写这个动作寄存器。
AXI-Lite 在 clk 域产生单周期事件，经 `back_ack_cdc` 的请求/确认握手跨入 pclk 域，
再产生一个周期的 `back_receive_done`。后续连续 ACK 写入会等待前一个事件完成跨域，
不会覆盖尚未送达的事件；AXI 写响应确认的是源端已接受事件，目的端随后解除等待。
`back_stream` 发完一帧后等待这个确认，确认后可接收下一次新图片触发。
PC 保存 BIN 和 PNG 成功后发 SAVED，PS 校验任务信息后写这个寄存器。
新增 `BACK_STATUS` 编号 0x31、字节偏移 0xC4；bit0=busy、bit1=waiting_ack、bit2=overflow。
三个状态经两级同步送入 clk 域。PS 等 busy 清零才发 DONE，防止确认尚未跨域时启动下一帧。
`back_busy`、`back_waiting_ack`、`back_overflow`、`back_frame_sent` 已标记为调试信号。

## 局部验证

```bash
python scripts/tests/run_display_checks.py
```

`tb_back_stream` 检查三张完整帧、模式锁存、反压稳定性、帧尾阻塞、ACK、复位、
FIFO 溢出短包、容量边界及单像素帧。
`tb_hdmi_out` 同时核对三帧 HDMI 输出和两帧 AXI 回传，确认黑边不计入回传、
反压不暂停 HDMI、模式重绘不会重复回传。
`tb_back_ack` 使用不同时钟，检查真实 AXI 写入触发、确认后发送下一帧、连续写入排队、
零值/WSTRB 屏蔽、复位时清除未送达事件以及复位后重新确认。
