# `tools/` —— ACZ7015 工程脚本

> 全部脚本已用 Vivado 2023.2 实测通过

---

## 脚本一览

| 脚本 | 用途 | 验证 |
|---|---|---|
| `env_check.ps1` | 环境一键自检 | ✅ 27 通过 / 2 警告 / 0 失败 |
| `register_board.tcl` | 注册 ACZ7015 板卡库 | ✅ |
| `create_pl_project.tcl` | 建纯 PL（Verilog）工程 | ✅ |
| `create_zynq_project.tcl` | 建 Zynq（PS+PL）工程 | ✅ 两种模式都过 |

---

## 1. `env_check.ps1` —— 环境自检

```powershell
powershell -ExecutionPolicy Bypass -File tools\env_check.ps1
```

检查 7 大类：Xilinx 工具链、器件支持、板卡文件、驱动、USB/串口、磁盘、工程模板。
退出码 0 = 就绪，1 = 有失败项。

> 脚本带 UTF-8 BOM。**若用编辑器改存，务必保留 BOM**，
> 否则 PowerShell 5.1 会按 ANSI 读中文注释导致语法错误。

---

## 2. `create_pl_project.tcl` —— 纯 PL 工程

```bat
vivado -mode batch -source tools\create_pl_project.tcl -tclargs <工程名> [目标目录] [顶层模块名]
```

**例：**
```bat
vivado -mode batch -source tools\create_pl_project.tcl -tclargs led_demo
vivado -mode batch -source tools\create_pl_project.tcl -tclargs led_demo D:\work led_flash
```

**产出：**
- 器件固定 `xc7z015clg485-2`
- 自动挂 `config/acz7015.xdc`
- 给了顶层名就生成一个带 1 Hz 心跳的顶层模板（验证时钟与复位用）

**实测结果：**
```
TOP     = led_flash
PART    = xc7z015clg485-2
SOURCES = ...\led_flash.v
CONSTRS = ...\config\acz7015.xdc
```

---

## 3. `create_zynq_project.tcl` —— Zynq 工程

```bat
vivado -mode batch -source tools\create_zynq_project.tcl -tclargs <工程名> [目标目录] [-axi] [-no_usb0] [-no_i2c0]
```

**例：**
```bat
vivado -mode batch -source tools\create_zynq_project.tcl -tclargs zynq_hello
vivado -mode batch -source tools\create_zynq_project.tcl -tclargs zynq_led D:\work -axi
```

**产出：**

| 模式 | Block Design 内容 |
|---|---|
| 默认 | `processing_system7`（套用 ACZ7015 预设）+ DDR/FIXED_IO 引出 |
| `-axi` | 另加 `axi_interconnect` + `proc_sys_reset` + `axi_gpio`(8bit→板上 LED) |

**实测结果（-axi 模式）：**
```
PS7_ENET0=1  PS7_USB0=1  PS7_I2C0=1
PS7_DDR=MT41K256M16 RE-125   PS7_BANK1=LVCMOS 1.8V   PS7_FCLK0=50
CELLS=/axi_gpio_led /axi_interconnect_0 /processing_system7_0 /rst_ps7_50M
TOP=system_wrapper
```

**踩过的坑（已修）：**
PS7 的 `M_AXI_GP0_ACLK` 必须回接 `FCLK_CLK0`，
否则 `validate_bd_design` 报 `[BD 41-758]`，`make_wrapper` 连带失败。
脚本里已在公共段处理，带存在性判断。

---

## 4. `register_board.tcl` —— 板卡注册

```tcl
source tools/register_board.tcl
```

把 `config/board` 加入 `board.repoPaths`，之后新建工程能在选板列表看到
`Xiaomeige ACZ7015 (Zynq-7015)`。

持久化方法见脚本末尾注释（推荐写 `Vivado_init.tcl`）。

---

## 完整上手流程

```powershell
# 1. 环境自检
powershell -ExecutionPolicy Bypass -File tools\env_check.ps1

# 2. 建纯 PL 工程（最快见效）
vivado -mode batch -source tools\create_pl_project.tcl -tclargs led_demo

# 3. 建 Zynq 工程（带 AXI）
vivado -mode batch -source tools\create_zynq_project.tcl -tclargs zynq_led D:\work -axi

# 4. 打开工程
vivado D:\work\zynq_led\zynq_led.xpr
```
