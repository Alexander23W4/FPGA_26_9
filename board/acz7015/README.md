# `board/` —— 板级支持包

> 器件：`xc7z015clg485-2`（小梅哥 ACZ7015，Zynq-7015）
> 这一层是**板子的**属性，不随项目变，独立于 `constrs/`（那是**项目的**约束）

```
board/
└── acz7015/
    ├── ps7_preset.tcl               PS7 一键配置 ★
    ├── board_files/                 Vivado Board File
    │   └── xiaomeige.com/acz7015/1.0/
    │       ├── board.xml
    │       ├── part0_pins.xml
    │       └── preset.xml
    └── drivers/                     板载 USB 转串口驱动（CH343/CH9102F）
```

---

## 1. PS7 预设

```tcl
source board/acz7015/ps7_preset.tcl
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

实测 MIO 树：
```
MIO0=GPIO   MIO1-6=QSPI   MIO7-15=GPIO
MIO16-27=Enet 0   MIO28-39=USB 0   MIO40-45=SD 0
MIO46-47=GPIO   MIO48-49=UART 1   MIO50-51=I2C 0   MIO52-53=Enet 0(MDIO)
```

**可选开关：**
```tcl
apply_acz7015_ps7_preset -no_usb0 -no_i2c0    ;# 复现原厂 Linux 基线配置
apply_acz7015_ps7_preset -fclk0 100           ;# FCLK0 改 100 MHz
apply_acz7015_ps7_preset -cell my_ps7         ;# 指定 PS7 单元名
```

> **为什么默认开 USB0/I2C0？**
> 原厂 Linux 基线把它们关了（USB0 当 GPIO、I2C0 走 EMIO），
> 但板上确实有 USB3320 ULPI PHY 和 MIO50/51 的 I2C0 通路，
> 所以本预设默认按硬件实际配置。要完全对齐原厂基线就加 `-no_usb0 -no_i2c0`。

---

## 2. 板卡文件

### 注册

```tcl
source scripts/tcl/register_board.tcl
# 之后 get_board_parts *acz7015* 返回:
#   xiaomeige.com:acz7015:part0:1.0
```

### 持久化

追加到 `<用户目录>\Xilinx\Vivado\2023.2\Vivado_init.tcl`：
```tcl
set_param board.repoPaths [list "<repo绝对路径>/board/acz7015/board_files"]
```

### ⚠️ 目录结构要求（踩过的坑）

Vivado 要求 `<repo根>/<厂商>/<板名>/<版本>/board.xml`。
**必须有厂商这一层目录**，否则静默忽略，`get_board_parts` 什么都返回不了。

### ⚠️ 已知限制

**`preset.xml` 里的 PS7 参数不会自动套用到 PS7 IP。**

实测：Vivado 的 board preset 机制对 Zynq PS7 只认**内置预设名**（如 `ZC702`），
自定义 `CONFIG.PCW_*` 列表被忽略 —— 加 PS7 进 BD 后仍是默认值
（DDR 变成 `MT41J128M8 JP-125`、Bank1 变成 3.3V）。

**所以 PS7 配置统一走 `ps7_preset.tcl`**（已实测通过）。

板卡文件的价值在于：**选板 + LED/按键/I2C 接口自动列出 + 引脚规划**。

---

## 3. 驱动

`drivers/` 下是板上 USB 转串口芯片 **CH9102F** 的驱动。

**为什么是 CH343SER：** 已核对 `CH343SER.INF`，其中明确包含
```
%CH9102SER.DeviceDesc% = CH343SER_Inst, USB\VID_1A86&PID_55D4
```
`VID_1A86 / PID_55D4` 就是 CH9102 系列。

装法：右键 `drivers/CH343SER/Driver/SETUP.EXE` → 以管理员身份运行。

---

## 4. 板级事实速查

| 项目 | 值 |
|---|---|
| FPGA | XC7Z015-2CLG485（图纸标 E 级，实物可能 I 级，**不影响工具链**） |
| DDR3 | 2× 4Gb x16 DDR3**L**，共 **1GB**，32 位，**1.35V** |
| eMMC | `KLM8G1GETF-B041` 8GB |
| QSPI Flash | `W25Q128JVSIQ` 16MB |
| Micro SD | 与 eMMC **共用 SD0（MIO40–45），不可同时使用** |
| PS 以太网 | `RTL8211F-CG`(U4) → PS_ENET0 |
| PL 以太网 | `RTL8211F-CG`(U10) → PL_ENET1 |
| USB-UART | `CH9102F`(U7) |
| USB-JTAG | 丝印 `M02HS2`(U8)，驱动待插板实测 |
| MIO Bank0 / Bank1 | **3.3V / 1.8V**（原理图 MIO[7]=0、MIO[8]=1） |

> **DDR3 必须选 `MT41K`（1.35V DDR3L），不能选 `MT41J`（1.5V）。**
> 实物可能是南亚 `NT5CC256M16ER-EKI`，但 MIG/PS7 器件库里没有南亚型号，
> 故统一按镁光 `MT41K256M16 RE-125` 配置（组织完全一致，可互换）。
