# `_env` — ACZ7015 开发环境与板卡事实库

> 本目录存放 **环境配置、工具链、板卡硬件事实** 相关的一切。
> 工程源码在 `../../vsrc`，本目录不参与综合。

---

## 目录导航

| 文件 | 内容 |
|---|---|
| `环境搭建指南.md` | CH343 驱动安装、Vitis 2023.2 补装、JTAG 验证（含完成记录） |
| `硬件核对表.md` | FPGA/DDR3/QSPI/连接器 逐条交叉验证结论 + 证据 |
| `drivers/CH343SER/` | CH9102F 串口驱动（已装到系统，此处留档） |
| `drivers/CH340SER_...exe` | 备选串口驱动 |
| `docs/_doc_连接器说明.txt` | 厂商原始文档：核心板板对板连接器 |
| `docs/_doc_图纸使用说明.txt` | 厂商原始文档：图纸使用说明 |

---

## 权威来源优先级

配置任何东西之前，按这个顺序采信：

| 级别 | 来源 |
|---|---|
| ★★★ | 实物丝印版本 |
| ★★★ | `09_硬件图纸\ACZ7015-CORE-原理图250804.pdf`（核心板） |
| ★★★ | `09_硬件图纸\ACZ7015-CB-RevA底板原理图.pdf`（底板） |
| ★★ | `09_硬件图纸\ACZ7015-CB-RevA-SCH\*.SchDoc`（Altium 源工程） |
| ✗ | `08_器件手册\` 芯片清单 —— **跨版本混装，不可作依据** |
| △ | `04_引脚信息\` xlsx —— 需与图纸交叉核对 |

---

## 已锁定的关键参数

### 工具链

| 项 | 值 |
|---|---|
| Vivado | ML Standard 2023.2 @ `E:\Xilinx\Vivado\2023.2` |
| Vitis | 2023.2 @ `E:\Xilinx\Vitis\2023.2` |
| Vitis HLS | 2023.2 @ `E:\Xilinx\Vitis_HLS\2023.2` |
| ARM GCC | `arm-xilinx-eabi-gcc` 12.2.0 |
| **PS 端 IDE** | **Vitis Unified IDE 2023.2**（Classic 未随 embedded 版安装，快捷方式是残留） |
| 器件 | `xc7z015clg485-2` |

### 板卡

| 项 | 值 |
|---|---|
| FPGA | XC7Z015-2CLG485（图纸标 E 级，实物可能是 I 级，**不影响工具链**） |
| DDR3 | 2× 4Gb x16 DDR3**L**，共 **1GB**，32 位，**1.35V** |
| DDR3 MIG 配置 | **`MT41K256M16XX-125`**，Data Rate **1066** |
| | ⚠️ 必须选 `MT41K`（1.35V），**不能选 `MT41J`**（1.5V） |
| eMMC | `KLM8G1GETF-B041` 8GB |
| QSPI Flash | `W25Q128JVSIQ` 16MB（MIO1–6） |
| Micro SD | 与 eMMC **共用 SD0（MIO40–45），不可同时使用** |
| PS 以太网 | `RTL8211F-CG`(U4) → PS_ENET0，MIO16–27 |
| PL 以太网 | `RTL8211F-CG`(U10) → PL_ENET1 |
| USB-UART | `CH9102F`(U7) → 驱动 CH343SER（VID_1A86&PID_55D4） |
| USB-JTAG | 丝印 `M02HS2`(U8)，驱动待插板实测 |
| MIO Bank0 | **3.3V**（MIO[7]=0） |
| MIO Bank1 | **1.8V**（MIO[8]=1） |

### 视频输出（本项目相关，重要）

| 端口 | 连接器 | 驱动方式 |
|---|---|---|
| **HDMI_1** | J6 | FPGA 并行 RGB → **SIL9022A**(U14) → TMDS |
| **HDMI_2** | J7 | **FPGA 原生 TMDS**（`DVI_TX0/1/2` + `DVI_CLK`，49.9Ω 端接） |
| LCD | J5 | FPGA 并行 RGB（与 HDMI_1 共用 RGB 总线） |

> ⚠️ 见 `硬件核对表.md` 第 8 节：本项目走 TMDS 编码路线，对应的是 **HDMI_2 (J7)**。

---

## 进度

| # | 项目 | 状态 | 位置 |
|---|---|---|---|
| 1 | CH343 驱动 | ✅ 完成并验证 | `_env/drivers/` |
| 2 | Vitis 2023.2 补装 | ✅ 完成并验证 | `E:\Xilinx\Vitis` |
| 3 | JTAG 驱动验证 | ⚪ **待插板** | — |
| 4 | PS7 Preset Tcl | ✅ 完成并验证 | `board/acz7015/ps7_preset.tcl` |
| 5 | ACZ7015 板卡文件 | ✅ 完成并验证 | `board/acz7015/board_files/` |
| 6 | 整理版 XDC | ✅ 完成 | `constrs/acz7015/acz7015.xdc` |
| 7 | 工程模板 Tcl ×2 | ✅ 完成并验证 | `scripts/tcl/create_pl_project.tcl` / `create_zynq_project.tcl` |
| 8 | 上板自检脚本 | ✅ 完成 | `scripts/env_check.sh`（bash） |
| 9 | 构建入口 `build.sh` | ✅ 完成 | `scripts/build.sh` |
| 10 | 仓库结构重构 | ✅ 完成 | 见下 |

---

## 仓库结构

```
FPGA_26_9/
├── rtl/                        ← FPGA 源码（按功能分层）
│   ├── top/  video/  storage/  imgproc/  common/
├── sim/tb/                     ← 仿真测试平台
│
├── constrs/acz7015/            ← 项目约束（详见 constrs/README.md）
│   ├── acz7015.xdc                  引脚约束模板（含时钟约束）
│   └── pinmap.csv                   引脚速查表
│
├── board/acz7015/              ← 板级支持包（详见 board/acz7015/README.md）
│   ├── ps7_preset.tcl               PS7 一键配置 ★
│   ├── board_files/xiaomeige.com/acz7015/1.0/
│   │   ├── board.xml                Vivado Board File
│   │   ├── part0_pins.xml
│   │   └── preset.xml
│   └── drivers/                     CH343/CH9102F 驱动
│
├── csrc/                       ← Vitis 工作区（你的 C 源码）
│   └── <组件名>/src/                平台名 / 应用名目录由 scripts 自动生成
│
├── scripts/                    ← 构建与自动化（详见 scripts/README.md）
│   ├── build.sh                     唯一入口 ★
│   ├── env_check.sh                 环境自检
│   ├── lib/common.sh                公共函数
│   ├── tcl/                         Vivado 执行层
│   └── vitis/                       PS 端执行层（Python 脚本）
│
├── docs/                       ← 文档（详见 docs/README.md）
│   ├── design/                      项目设计文档
│   ├── reference/                   参考资料
│   └── env/                         本目录（环境与硬件事实库）
│
├── bd/  ip/                    ← 预留：Block Design Tcl / 自定义 IP
└── build/                      ← 生成物（git 忽略）
```

---

## 快速上手

```bash
# 1. 环境自检
./scripts/build.sh check

# 2. 纯 PL 全流程
./scripts/build.sh pl -n led_demo -t led_flash

# 3. Zynq 全流程（带 AXI）
./scripts/build.sh zynq -n zynq_led -a
```

---

## 唯一未完成项

**插板实测 JTAG**。板载 JTAG 芯片丝印 `M02HS2`，非标准型号也无数据手册。
USB-C 接 J2 调试口（丝印 `HUB / JTAG / UART`）+ 上电后，跑：
```bash
./scripts/build.sh check
# 或直接看 USB 设备：
powershell.exe -NoProfile -Command "Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -match 'VID_1A86|VID_0403|VID_1443' } | Select-Object Status,Class,FriendlyName,InstanceId"
```
期望：新增一个 `USB-Enhanced-SERIAL CH9102 (COMx)` + 一个 JTAG 设备。

