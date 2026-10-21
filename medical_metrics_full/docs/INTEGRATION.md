# 与队友仓库的接口对齐和上板接入

## 1. 以哪套接口为准

队友仓库当前实际编译链是：

```text
rtl/top1.v
  └─ rtl/thresholder/top_threshold_demo.v
       └─ rtl/thresholder/axi_lite_slave.v
csrc/MID_plt/src/config/pl_cmd.h
```

`pl_cmd.h` 中的寄存器值是 **WORD 索引**，不是字节偏移：

```c
#define PL_REG_OFFSET(index)  ((unsigned)(index) << 2u)
#define PL_REG_ADDRESS(index) (PL_CTRL_BASE + PL_REG_OFFSET(index))
```

已有映射（以当前 `axi_lite_slave.v` 为准）：

| WORD | 字节偏移 | 名称 | 说明 |
|---:|---:|---|---|
| 0x00 | 0x00 | MODE | 模式 |
| 0x01 | 0x04 | CMD | 自动/手动阈值 |
| 0x02 | 0x08 | VIDEO_MODE | 显示模式 |
| 0x03 | 0x0C | STATUS | 实际阈值回读 |
| 0x04 | 0x10 | HDMI_EN | HDMI 使能 |
| 0x20 | 0x80 | DATA | 手动阈值 |
| 0x21 | 0x84 | AREA | 当前帧前景像素数 |
| 0x22 | 0x88 | MASK_ALPHA | 叠加透明度 |
| 0x31 | 0xC4 | BACK_STATUS | 回传状态 |
| 0x32 | 0xC8 | BACK_FRAME_MODE | 回传模式 |
| 0x33..0x36 | 0xCC..0xD8 | 回传计时/时钟 | 统计 |

仓库里的 `rtl/axi_lite_rcv.v` 是另一套旧映射（0x00/0x10/0x20/0x30...）。当前 `top1.v` **没有实例化它**，所以不要用它的 0x10/0x20 地址去接 PS。

## 2. 新增医疗寄存器

本包使用同一套 WORD 索引，新增 `0x40..0x4F`：

| WORD | 字节偏移 | 名称 | 读/写 | 内容 |
|---:|---:|---|---|---|
| 0x40 | 0x100 | MED_CTRL | R/W | bit0=1 重启 ED/ES 跟踪 |
| 0x41 | 0x104 | MED_STATUS | R | bit0 reg_valid, bit1 volume_busy, bit2 tracker_valid, bit3 strain_busy |
| 0x42 | 0x108 | DX | R | 配准 dx，16-bit 有符号扩展 |
| 0x43 | 0x10C | DY | R | 配准 dy |
| 0x44 | 0x110 | SAD | R | 最佳 SAD |
| 0x45 | 0x114 | AREA | R | 当前帧掩膜面积（像素） |
| 0x46 | 0x118 | LENGTH | R | 当前帧长轴（像素） |
| 0x47 | 0x11C | EDV_LO | R | EDV Q16.16 低 32 位 |
| 0x48 | 0x120 | EDV_HI | R | EDV Q16.16 高 32 位 |
| 0x49 | 0x124 | ESV_LO | R | ESV Q16.16 低 32 位 |
| 0x4A | 0x128 | ESV_HI | R | ESV Q16.16 高 32 位 |
| 0x4B | 0x12C | STRAIN_LO | R | 简化应变 Q16.16 低 32 位 |
| 0x4C | 0x130 | STRAIN_HI | R | 简化应变 Q16.16 高 32 位 |
| 0x4D | 0x134 | ED_FRAME | R | ED 帧号 |
| 0x4E | 0x138 | ES_FRAME | R | ES 帧号 |
| 0x4F | 0x13C | FRAME_ID | R | 已处理帧号 |

Q16.16 换算：

```c
float ml = (float)q16 / 65536.0f;
float percent = (float)strain_q16 / 65536.0f;
```

## 3. 方案 A：单独增加一个 AXI-Lite 从口（推荐，改动最小）

在 Block Design 中给 `medical_accel_top` 增加一个 AXI-Lite 从口，地址分配为：

```text
0x44010000
```

这样 PS 看到的字节地址是：

```text
0x44010000 + (0x40 << 2) = 0x44010100
0x44010000 + (0x4F << 2) = 0x4401013C
```

`csrc/medical_metrics.h` 默认就是 `MED_CTRL_BASE = 0x44010000`。如果你在 Address Editor 里分了别的地址，只需要改这个宏。

## 4. 方案 B：合并进现有 `axi_lite_slave.v`

如果不想增加 AXI-Lite 从口，可以把 `rtl/medical_axi_lite.v` 中的 case 项复制到队友的 `axi_lite_slave.v`，并增加对应端口：

```verilog
localparam [6:0] ADDR_MED_CTRL   = 7'h40,
                 ADDR_MED_STATUS = 7'h41,
                 ADDR_DX         = 7'h42,
                 ADDR_DY         = 7'h43,
                 ADDR_SAD        = 7'h44,
                 ADDR_AREA_MED   = 7'h45,
                 ADDR_LENGTH_MED = 7'h46,
                 ADDR_EDV_LO     = 7'h47,
                 /* ... 0x48..0x4F ... */;
```

写通道只允许 `ADDR_MED_CTRL`，其余医疗寄存器只读；读通道把 `medical_accel_top` 的 `reg_dx/reg_dy/...` 接进来。合并后编译 C 时加：

```text
-DMED_CTRL_BASE=0x44000000u
```

## 5. 像素流接线

在 `top1.v` 中，`top_threshold_demo` 当前输出：

```verilog
.m_axis_tdata(ts_data),
.m_axis_tvalid(hdl_valid),
.m_axis_tready(hdl_ready),
.m_axis_tlast(hdl_eof),
.m_axis_tmask(ts_mask),
.m_axis_tcontour(ts_contour)
```

把 `medical_accel_top` 串在它后面：
把 `medical_accel_top` 串在 `top_threshold_demo` 和 `hdl_out` 之间。它会把原图、mask、contour 透传给 `hdl_out`，同时在内部做配准和定量：

```verilog
wire        med_s_tready;
wire [7:0]  med_m_data;
wire        med_m_valid, med_m_last, med_m_mask, med_m_contour;

medical_accel_top #(
    .FRAME_W(256), .FRAME_H(256),
    .ROI_W(48), .ROI_H(48), .SEARCH_R(8),
    .PIXEL_AREA_Q8(24),   // 0.308 mm * 0.308 mm，Q8 近似
    .SPACING_Y_Q8(79)     // 0.308 mm，Q8 近似
) u_medical (
    .clk(clk), .rst(rst_clk),

    .s_axis_tdata(ts_data),
    .s_axis_tvalid(hdl_valid),
    .s_axis_tready(med_s_tready),
    .s_axis_tlast(hdl_eof),
    .s_axis_tmask(ts_mask),
    .s_axis_tcontour(ts_contour),

    .m_axis_tdata(med_m_data),
    .m_axis_tvalid(med_m_valid),
    .m_axis_tready(hdl_ready),       // 来自 hdl_out
    .m_axis_tlast(med_m_last),
    .m_axis_tmask(med_m_mask),
    .m_axis_tcontour(med_m_contour),

    // 方案 A：第二个 AXI-Lite 从口
    .awaddr(med_awaddr), .awvalid(med_awvalid), .awready(med_awready),
    .wdata(med_wdata), .wstrb(med_wstrb), .wvalid(med_wvalid), .wready(med_wready),
    .bresp(med_bresp), .bvalid(med_bvalid), .bready(med_bready),
    .araddr(med_araddr), .arvalid(med_arvalid), .arready(med_arready),
    .rdata(med_rdata), .rresp(med_rresp), .rvalid(med_rvalid), .rready(med_rready),

    .dbg_status(med_dbg_status)
);
```

同时把 `top_threshold_demo` 的 `m_axis_tready` 改成 `med_s_tready`，把 `hdl_out` 的输入改成 `med_m_*`：

```verilog
top_threshold_demo u_top_threshold_demo (
    /* ... */
    .m_axis_tready(med_s_tready),
    /* ... */
);

hdl_out u_hdl_out (
    .hdl_data(med_m_data),
    .hdl_mask(med_m_mask),
    .hdl_contour(med_m_contour),
    .hdl_valid(med_m_valid),
    .hdl_eof(med_m_last),
    .hdl_ready(hdl_ready),
    /* ... */
);
```

注意：`medical_accel_top` 在搜索/拷贝期间会拉低 `med_s_tready`，从而反压 `top_threshold_demo`；`m_axis_tready=hdl_ready` 保证下游忙时不会丢像素。`m_axis_tvalid` 由上游 valid 和内部 ready 共同决定，符合 AXI-Stream 反压语义。

## 6. 关键时序/资源注意事项

- `medical_accel_top` 默认 `ROI=48x48`、`SEARCH_R=8`。搜索期间会拉低 `s_axis_tready`，因此上游必须正确遵守 AXI-Stream 反压。
- 两个 256x256x8 帧缓存约 128 KB，约 28 个 BRAM36；加上队友现有 double buffer，资源需要 Vivado 实测。
- SAD 搜索约 1.33M cycles；80 MHz 下约 16.6 ms，帧拷贝约 1.6 ms。若不能接受，先把 `ROI_W/ROI_H` 改为 32 或 `SEARCH_R` 改为 4。
- `volume_calc` 使用 64 周期除法器，每帧一次，不构成瓶颈。
- 所有 RTL 使用同步 RAM 和单时钟 `clk`；如果 `ts_data` 在 `clk` 域，直接接；如果跨时钟域，必须加异步 FIFO，不能直接接。

## 7. PS 端使用

把 `csrc/medical_metrics.c/.h` 加入 `csrc/MID_plt/src`，在应用里：

```c
#include "medical_metrics.h"

medical_metrics_t m;
medical_metrics_restart();       // 开始一个心动周期
/* ... 连续送入帧 ... */
medical_metrics_read(&m);
medical_metrics_print(&m);
```

`medical_metrics_print` 会输出：

```text
MED status=...
  reg dx=... dy=... SAD=...
  area=... px, long axis=... px
  EDV=... mL, ESV=... mL, EF=...%
  GLS surrogate=...% (ED frame ..., ES frame ...)
```

## 8. 必须在上板前确认的点

1. 在 Vivado 里确认第二个 AXI-Lite 从口的地址确实是 `0x44010000`，且没有和 VDMA/其他 IP 冲突。
2. 用 `tb_registration_top` 验证 `dx=+2, dy=-1, SAD=0`。
3. 用 `tb_volume_calc` 验证 `volume_q16=6337`、`strain_q16=-1310720`。
4. 用 `tb_area_axis` 验证面积 8、长轴 2。
5. 用 `tb_medical_axi_lite` 验证寄存器读写。
6. 综合后看 `report_utilization` 和 `report_timing_summary`；本包没有本机综合结果。
