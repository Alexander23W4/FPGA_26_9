# `constrs/` —— 约束文件

```
constrs/
└── acz7015/
    ├── acz7015.xdc       板级引脚约束模板（含时钟约束）
    └── pinmap.csv        引脚总表速查
```

---

## `acz7015.xdc` 的定位

这是**板级引脚模板**，不是最终约束文件。端口名沿用**小梅哥官方例程**的命名。

| 情况 | 做法 |
|---|---|
| 你的顶层端口名和它一致 | 直接用 |
| 不一致 | 只复制用到的段落，改端口名 |
| 用不到的段落 | **整段注释掉**，否则 `get_ports` 找不到对象会报错 |

如果顶层模块端口和 XDC 里有任何一处对不上，Vivado 会在综合时报
`[Common 17-55] 'set_property' expects at least one object`。

---

## 已包含的时钟约束

原版 XDC 只有摄像头那一条，整理时补上了系统时钟：

```tcl
# 系统时钟：板上 50 MHz 有源晶振 → FPGA L5
create_clock -period 20.000 -name sys_clk [get_ports clk50M]

# 摄像头像素时钟（OV5640 PCLK 输入）
create_clock -period 13.888 -name Cam_PCLK [get_ports Cam_PCLK]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets Cam_PCLK_IBUF]
```

> 顶层端口若叫 `clk` 或 `clk_in50M`，把 `clk50M` 换成对应名字即可。
> 官方所有例程（led_flash / key_led / pwm_gen / tft800x480_ctrl）的系统时钟都在 **L5**。

---

## 关键引脚（官方例程一致，已核对）

| 信号 | 引脚 | 说明 |
|---|---|---|
| **系统时钟 50 MHz** | **L5** | 所有例程一致 |
| 复位按键 | R4 | |
| 8 位 LED | AB14 AA14 AA15 AA12 R17 T17 U19 V19 | |
| 4 位按键 | AB12 V11 W11 AA11 | |
| 蜂鸣器 | R2 | |
| **HDMI_2 原生 TMDS** | 数据 N6 / M8 / K7，时钟 T2 | IOSTANDARD 必须 `TMDS_33` |

完整表见 `pinmap.csv`。

---

## 关于两个 HDMI

板上两个 HDMI 口走**完全不同的两条路**，别搞混：

| 端口 | 连接器 | 驱动方式 | 需要什么 |
|---|---|---|---|
| **HDMI_1** | J6 | FPGA 并行 RGB → **SIL9022A** → TMDS | 输出 24bit RGB + HSYNC/VSYNC/DE/PCLK，另需 I2C 初始化 |
| **HDMI_2** | J7 | **FPGA 原生 TMDS** | 7 系列 OSERDESE2 做 10:1 串行化 |

`acz7015.xdc` 第 2 节是 **HDMI_2**（TMDS）那一路的约束。

---

## 每次建工程都自动挂载

`scripts/tcl/create_pl_project.tcl` 和 `create_zynq_project.tcl` 会自动把
本目录下的 `acz7015.xdc` 加进 `constrs_1`。

用 `build.sh` 的话就是：

```bash
./scripts/build.sh pl -n led_demo -t led_flash
```
