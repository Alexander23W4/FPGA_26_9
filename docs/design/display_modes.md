# HDMI 显示模式与寄存器（2026-10-16）

## 地址规则

`pl_cmd.h` 的 `*_ADDR` 表示 **32 位寄存器编号**。AXI-Lite 和
`Xil_In32/Out32` 使用字节地址，PS 统一通过 `PL_REG_ADDRESS(index)` 换算：
`0x44000000 + (index << 2)`。不要直接把编号加到基地址上。

| 寄存器 | 编号 | 字节偏移 | 说明 |
| --- | --- | --- | --- |
| MODE | 0x00 | 0x00 | 0 图像处理；1 医学分析预留 |
| CMD_REG | 0x01 | 0x04 | 0 自动阈值；1 手动阈值 |
| VIDEO_MODE | 0x02 | 0x08 | HDMI 模式 0～4 |
| STATUS | 0x03 | 0x0C | 只读：PL 实际使用的阈值 |
| DATA_REG | 0x20 | 0x80 | 手动阈值 0～255 |
| LESION | 0x21 | 0x84 | 只读：上一完整输出帧的掩膜像素数，0～65536 |
| MASK_TRANSP | 0x22 | 0x88 | 掩膜不透明度 0～100，复位为 45 |
| BACK_RECEIVE | 0x30 | 0xC0 | 写 bit0=1 触发回传确认，自动清零；读回 0 |
| BACK_STATUS | 0x31 | 0xC4 | 只读：bit0 busy、bit1 waiting_ack、bit2 overflow |

AXI 写地址和写数据可分开到达，支持 WSTRB。未对齐、未映射以及写只读寄存器
返回 SLVERR。该地址表用于当前 `top1` + `MID_plt` 串口链路；
`network/ps_baremetal` 是独立网络演示工程，使用自己的协议，不作为当前固件。

自动阈值按当帧直方图计算后回放分割，具体时序、比较边界及验证见 [otsu.md](otsu.md)。

## 显示模式

| 值 | HDMI 图像 |
| --- | --- |
| 0 | 去噪灰度图 |
| 1 | 灰度图上叠加白色轮廓 |
| 2 | 黑白二值掩膜 |
| 3 | 灰度图上叠加红色掩膜 |
| 4 | 灰度值映射为伪彩色；这不是模型置信度图 |

模式 3 在 mask=1 的像素使用整数混合：
`R=((100-a)*gray+a*255)/100`，`G=B=(100-a)*gray/100`，结果向下取整。
0% 完全透明，100% 实心红色；mask=0 保留灰度。
模式 4 的颜色依次经过深蓝、蓝、青、绿、黄、暗红。
GUI 的“全显示”（值 5）按 0→1→2→3→4 顺序执行五轮网口处理，同一原图发送五次。
每轮先通过串口 V 命令让 PS 写 AXI-Lite VIDEO_MODE 并回读确认，随后发图、
保存并校验对应 BIN、发送 SAVED，由 PS 写 BACK_RECEIVE（receive_done）。
收到 DONE 后 GUI 从该 BIN 加载处理图，再进入下一轮。六宫格显示原图及五张处理图；
值 5 只用于 GUI 编排，不写入 FPGA 模式寄存器。单独模式执行同样流程一次，显示原图与处理图。

帧缓存同时保存灰度、mask、contour，三路使用相同写使能、bank 和地址。
显示配置通过握手跨入像素时钟域，在 HDMI 帧边界生效；
切换模式或透明度可直接重绘当前图像，无需再次发送 D。
RGB 与 HS/VS/DE 使用相同的两级流水线，图像区域外保持黑色。

### 显示链路分工

像素数据依次经过：`double_buf → out_arr → hdmi_out → hdmi_tx`。
`out_arr` 锁存每帧显示配置，并通过内部 `video_colorizer` 完成五种模式的 RGB 计算。
`hdmi_out` 接收计算后的 RGB，产生并对齐 HS/VS/DE，再统一输出给 `hdmi_tx`。
缓存读地址、bank、图像窗口和帧边界仍由 `hdmi_out` 的扫描计数生成。
RGB 计算保留两级流水线，HS/VS/DE 在 `hdmi_out` 内经过相同级数；
首张完整图片到达后持续扫描，无新图片时刷新当前缓存。

PL 的单像素 AXI 回传支路见 [back_stream.md](back_stream.md)。
GUI 的直接网口发图与保存回传结果见 [network_ddr.md](network_ddr.md)。

## GUI / PS 命令

- `V + 1 字节`：模式 0～4。
- `P + 1 字节`：掩膜不透明度 0～100。
- `T + 模式字节 + 阈值字节`：阈值模式及手动阈值。
- `R`：回读七个配置/状态寄存器，不包含 BACK_RECEIVE 动作寄存器；打印地址为寄存器编号。
- `M + 1 字节`：系统模式 0/1，医学分析算法预留。
- GUI 的模式下拉框与透明度更新按钮会检查 PS 的寄存器回读；地址表不匹配、
  缺少确认或回读不一致均报告失败。PS 同样验证写后回读。
- `D` 的单帧发送逻辑保持原有行为，输入仍是 65536 字节的 256×256×8-bit BIN。

## 本地验证

```bash
python scripts/tests/run_display_checks.py
python -m unittest discover -s network/host -p 'test_*.py'
```

XSim 脚本只编译和仿真，不综合、不连接开发板；日志在 `build/tests/display/`。
覆盖：AXI 新地址/独立 AW/W/WSTRB/响应保持、面积 65536 回读、五种模式的像素结果、
全部 101×256 种透明度与灰度组合、两帧写入/三帧显示、跨时钟配置及无新图重绘。

## 重新构建与下载

新地址表需要 PS、PL 一起更新。仓库根目录 Git Bash：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f && bash ./scripts/flash_current.sh init
```

已有 Vivado 工程会先补入新增 RTL，再刷新模块引用。
局部仿真通过不代表整机资源、布局布线和时序已通过，仍以完整实现报告及上板结果为准。
