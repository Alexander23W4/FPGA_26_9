# `config/` —— ACZ7015 板级配置

> 器件：`xc7z015clg485-2`（小梅哥 ACZ7015，Zynq-7015）

---

## 文件一览

| 文件 | 用途 | 验证状态 |
|---|---|---|
| `acz7015_ps7_preset.tcl` | **PS7 一键配置**（MIO/DDR/时钟/电压） | ✅ Vivado 实测通过 |
| `acz7015.xdc` | 板级引脚约束模板（整理版） | ⚠️ 模板，需按顶层端口名取用 |
| `acz7015_pinmap.csv` | 引脚总表速查 | 数据源自官方例程 |
| `board/xiaomeige.com/acz7015/1.0/` | Vivado Board File | ✅ 可被 `get_board_parts` 识别 |

---

## 1. PS7 预设（最常用）

在 Block Design 的 Tcl Console 里：

```tcl
source C:/Users/HUAWEI/Desktop/FPGA_26_9/config/acz7015_ps7_preset.tcl
apply_acz7015_ps7_preset
```

**实测生效结果：**

| 项目 | 值 |
|---|---|
| APU | 666.666666 MHz |
| DDR PLL / DDR 频率 | 1066.667 / 533.333 MHz（DDR3-1066） |
| DDR 器件 | `MT41K256M16 RE-125`，32 Bit，1 GB |
| FCLK0 | 50 MHz |
| Bank0 / Bank1 电压 | 3.3V / **1.8V** |
| QSPI | MIO 1..6（W25Q128，x4，单 CS） |
| ENET0 | MIO 16..27 + MDIO MIO 52..53 |
| USB0 | MIO 28..39（ULPI） |
| SD0 | MIO 40..45（4bit） |
| UART1 | MIO 48..49 |
| I2C0 | MIO 50..51 |
| GPIO | MIO + EMIO(2) |

**可选开关：**

```tcl
apply_acz7015_ps7_preset -no_usb0 -no_i2c0      ;# 复现原厂 Linux 基线配置
apply_acz7015_ps7_preset -fclk0 100             ;# FCLK0 改 100 MHz
apply_acz7015_ps7_preset -cell my_ps7           ;# 指定 PS7 单元名
```

> **为什么默认开 USB0/I2C0？**
> 原厂 Linux 基线把它们关了（USB0 改成 GPIO、I2C0 走 EMIO），
> 但板上确实有 USB3320 ULPI PHY 和 MIO50/51 的 I2C0 通路，
> 所以本预设默认按硬件实际配置。要完全对齐原厂基线就加 `-no_usb0 -no_i2c0`。

---

## 2. 板卡文件

### 注册

```tcl
source C:/Users/HUAWEI/Desktop/FPGA_26_9/tools/register_board.tcl
```

注册后 `get_board_parts *acz7015*` 返回：
```
xiaomeige.com:acz7015:part0:1.0
```

### 持久化

追加到 `<用户目录>\Xilinx\Vivado\2023.2\Vivado_init.tcl`：
```tcl
set_param board.repoPaths [list "C:/Users/HUAWEI/Desktop/FPGA_26_9/config/board"]
```

### 目录结构要求（踩过的坑）

Vivado 要求 `<repo根>/<厂商>/<板名>/<版本>/board.xml`。
必须有**厂商这一层目录**，否则静默忽略。

```
config/board/
└── xiaomeige.com/          ← 厂商层，必须有
    └── acz7015/
        └── 1.0/
            ├── board.xml
            ├── part0_pins.xml
            └── preset.xml
```

### ⚠️ 已知限制

**`preset.xml` 里的 PS7 参数不会自动套用到 PS7 IP。**
Vivado 的 board preset 机制对 Zynq PS7 只认内置预设名（如 `ZC702`），
自定义 `CONFIG.PCW_*` 列表实测不生效。

**所以：PS7 配置请统一走 `acz7015_ps7_preset.tcl`**（已实测通过）。
板卡文件的价值在于：选板 + LED/按键/I2C 接口自动列出 + 引脚规划。

---

## 3. 引脚约束模板

`acz7015.xdc` 是**模板**，端口名沿用官方例程命名。

- 顶层端口名和它一致 → 直接用
- 不一致 → 只复制用到的段落，改端口名
- **用不到的段落要注释掉**，否则 `get_ports` 找不到对象会报错

引脚含义速查见 `acz7015_pinmap.csv`。

### 已加入的时钟约束

```tcl
create_clock -period 20.000 -name sys_clk [get_ports clk50M]   ;# L5, 50 MHz
create_clock -period 13.888 -name Cam_PCLK [get_ports Cam_PCLK] ;# 摄像头
```

原版 XDC 只有摄像头那一条，系统时钟约束是本次补上的。

### 关键引脚（官方例程一致）

| 信号 | 引脚 |
|---|---|
| 系统时钟 50 MHz | **L5** |
| 复位按键 | R4 |
| 8 位 LED | AB14 AA14 AA15 AA12 R17 T17 U19 V19 |
| 4 位按键 | AB12 V11 W11 AA11 |
| 蜂鸣器 | R2 |
| **HDMI_2 原生 TMDS** | 数据 N6 / M8 / K7，时钟 T2 |
| TFT LCD | 见 CSV |
| PL 千兆以太网 | 见 CSV |
