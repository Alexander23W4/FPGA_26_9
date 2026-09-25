# PS SD0（MIO40..45）存储诊断报告

> ## ✅ 已解决（2026-09-25）
>
> **根因：microSD 卡座里插着卡 → 把板载 eMMC 顶掉了。**
> 把卡拔掉 + 断电重上电之后，eMMC 立刻正常：
>
> ```
> CardInitialize: 0  (OK)
> CardType      : 2  -> MMC / eMMC
> HCS           : 1   (block addressed)
> BusSpeed      : 52000000 Hz          <- 52MHz 高速模式
> BlkSize       : 512
> SectorCount   : 15269888  (= 7456 MB)  <- ≈8GB，正是 KLM8G1GETF-B041
> ```
>
> 这正好坐实了原厂引脚表那句 **"PS SD0 / eMMC ⚠ 两者不可同时使用"**：
> **卡座和 eMMC 共用 MIO40..45，插卡 = eMMC 被断开。**
>
> 而底板的 microSD 座是 3.3V 设计、MIO Bank1 是 1.8V，所以**卡本身也永远不能用**。
> 结论：**这块板子要用存储，就用 eMMC，并且卡座里不能插卡。**
>
> 已经做好的加载工具：
> - PS 端：`csrc/MID_plt/src/main.c`（UART → DDR → eMMC → 回读校验）
> - PC 端：`scripts/pc/emmc_load.ps1`
> - 实测：512 KB（1024 块）写入 + 回读 + 逐字节比对，**0 差异**，用时 54 秒
>
> 下面保留完整排查过程和全部证据，供以后遇到类似问题参考。

---

> 排查阶段的结论（已被上面推翻）：~~PS SD0 上没有任何存储设备会应答。~~
> 真正的原因是**插座里的卡把 eMMC 顶掉了**，而不是 eMMC 不在。


---

## 1. 现象

`f_open()` 返回 `FR_NOT_READY (3)`，`f_mount(opt=1)` 也失败。
串口探针（`csrc/MID_plt/src/main.c`）逐条命令打出来：

| 命令 | 是否需要应答 | 结果 | 含义 |
|---|---|---|---|
| CMD0（GO_IDLE_STATE） | 不需要 | **CC=1，793 圈空循环** | SD 时钟在翻转，控制器/CMD/DAT 焊盘都好 |
| CMD8 (0x0802) 宽松版 | 需要 R7 | **Command Timeout (ERR bit0)** | 没有 SD 卡应答 |
| CMD8 (0x081A) 严格版 | 需要 R7 | **Command Timeout** | 同上 |
| CMD1 (0x0102) arg=0x40FF8000 | 需要 R3 | **Command Timeout** | **没有 eMMC/MMC 应答** |
| CMD55 (0x371A) | 需要 R1 | **Command Timeout** | 没有 SD 卡应答（CMD55 是 SD 专用） |

**关键点：CMD0 是"无应答"命令，它成功只证明 48 bit 被时钟移出去了 —— 完全不能证明卡是活的。**
真正能证明卡在应话的是 CMD8 / CMD1 / CMD55，而它们**全部静默超时**。

---

## 2. 控制器侧全部正常

```
CfgInitialize : 0  (OK)
POWER_CTRL    : 0x0F   (bus_pwr=1 vsel=7 -> 3.3V)
CLK_CTRL      : 0x8007 (bit0=1 内部时钟使能, bit1=1 稳定, bit2=1 SD时钟输出, div=128 -> 390.6 kHz)
HOST_CTRL1    : 0x10
PSR           : 0x01FF0000  CMD 线=1(高), DAT3:0=全部为 1
HC_Version    : 1  (= XSDPS_HC_SPEC_V2)
Host_Caps     : 0x69EC0080
```

- 分频 128 → 100 MHz / 256 = **390.6 kHz**，完全符合 SD 初始化要求的 400 kHz 档。
- PSR 里 CMD 线和 DAT 线都是高（空闲态），说明**焊盘电气上是好的**。
- 所以：**控制器、时钟、CMD/DAT 线、驱动流程都没问题，问题在"卡为什么不应答"。**

---

## 3. PS7 配置：和原厂完全一致（不是配置写错了）

`docs/env/_ref/ps7_linuxbase_config.txt`（原厂 ACZ7015 配置基线）里：

```
PCW_PRESET_BANK1_VOLTAGE    LVCMOS 1.8V
PCW_MIO_40..45_IOTYPE       LVCMOS 1.8V
PCW_SD0_SD0_IO              MIO 40 .. 45
PCW_SD0_GRP_CD_ENABLE       0
PCW_SD0_GRP_WP_ENABLE       0
PCW_SD0_GRP_POW_ENABLE      0
```

`board/acz7015/ps7_preset.tcl` 里我们的设置**逐条相同**。生成的 `ps7_init.tcl`：

```
mask_write 0XF80007A0 0x00003FFF 0x00001280   # MIO40  0x1280
mask_write 0XF80007A4 0x00003FFF 0x00001280   # MIO41
mask_write 0XF80007A8 0x00003FFF 0x00001280   # MIO42
mask_write 0XF80007AC 0x00003FFF 0x00001280   # MIO43
mask_write 0XF80007B0 0x00003FFF 0x00001280   # MIO44
mask_write 0XF80007B4 0x00003FFF 0x00001280   # MIO45
```

`MIO_PIN_xx` 字段解码（`0xF8000700 + 4*n`）：

| 字段 | bit | 0x1280 |
|---|---|---|
| TRI_ENABLE | 0 | 0（输出使能） |
| L2_SEL | 4:3 | 0 |
| **L3_SEL** | **7:5** | **4 = SDIO0** |
| Speed | 8 | 0（slow） |
| **IO_Type** | **11:9** | **001 = LVCMOS 1.8V** |
| PULLUP | 12 | 1（内部上拉开） |
| DisableRcvr | 13 | 0 |

对照同文件里别的引脚可以确认编码：`MIO0 = 0x1600`（IO_Type=011=**3.3V**，Bank0）、`MIO16 = 0x1202`（IO_Type=001=**1.8V**，Bank1）。
→ **Bank0 = 3.3V，Bank1 = 1.8V。MIO40..45 属于 Bank1，是 1.8V。**

---

## 4. 底板原理图：microSD 座是 **3.3V 设计**

`docs/reference/ACZ7015-CB-RevA底板原理图.pdf` 第 10 页 `SD_Card` 区块，插座 **J8 (MicroSD_SOCKET)**：

```
                 VCC3P3
                   |
        +----------+----------+----------
        |          |          |
      R90 68K    R91 68K    R92 68K
        |          |          |
   PS_SD_DATA2  PS_SD_DATA3  PS_SD_CMD   -> J8 pin1/2/3 (DAT2 / DAT3-SC / CMD-MOSI)
                            VCC3P3 -------> J8 pin4  (VDD)
                            PS_SD_CLK -----> J8 pin5  (CLK)
                                            J8 pin6  (GND)
      R93 68K    R94 68K
   PS_SD_DATA0  PS_SD_DATA1              -> J8 pin7/8 (DATA0-MISO / DATA1-IRQ)
   PS_SD_CD   -------------------------> J8 pin9  (CARD_INSTER)
                                            J8 pin10/11 (GND)
   C104 0.1uF 在 VCC3P3 上
```

**结论：插座 VDD = VCC3P3（3.3V），DATA0..3/CMD 全部用 68K 上拉到 VCC3P3。这是一个 3.3V 电平的卡座。**

而 MIO Bank1 是 1.8V：

- 卡收到的高电平只有 **~1.8V**，低于 SD 卡在 3.3V 供电下的 `V_IH ≈ 0.625 × 3.3 = 2.06V`
  → **卡把命令当成无效电平，干脆不应答** ← 和实测的"全部 Command Timeout"完全吻合。
- 反过来卡驱动的 3.3V 高电平进 1.8V 的 MIO，还要靠 68K 限流，属于擦边设计。

---

## 5. 决定性实验：把 MIO40..45 强行改成 3.3V 后，连 CMD0 都发不出去

用 JTAG 在线改写这 6 个寄存器（不用重新综合），值是 `0x1680`（IO_Type 改成 011 = 3.3V，其余位不变）：

```
[sd33] MIO40..45 BEFORE: 0xF80007A0 = 0x00001280   (LVCMOS 1.8V)
[sd33] MIO40..45 AFTER : 0xF80007A0 = 0x00001680   (LVCMOS 3.3V)   <- 回读确认写入成功
```

然后重跑同一份 ELF：

| 配置 | CMD0 结果 |
|---|---|
| IO_Type = 1.8V（原值） | **CC=1，793 圈** ✅ |
| IO_Type = 3.3V（改后） | **CMD TIMEOUT + CMD CRC ERROR**（500 万圈跑满）❌ |

**改坏的正是"能发命令"这件事本身。**
这是"焊盘物理供电是 1.8V，却被配成 3.3V 输入阈值"的典型症状：
CMD 线空闲在 1.8V，3.3V 阈值的接收器把它读成 **0**，命令状态机永远等不到空闲，于是超时。

→ **实测证明 `VCCIO_BANK1` 就是 1.8V，不能靠软件配置改成 3.3V。**

（实验后已用 `flash_app.tcl init` 重跑 ps7_init，把 MIO40..45 恢复成 `0x1280`。）

---

## 6. 原厂自己的警告

`constrs/acz7015/pinmap.csv`：

```
PS_MIO40..45,-,LVCMOS18,PS SD0 / eMMC,⚠ 两者不可同时使用
```

**"两者不可同时使用"** —— 底板的 microSD 卡座和核心板上的 eMMC 共用 MIO40..45，
必须二选一；而且这个 Bank 的 1.8V 是为 **eMMC** 准备的，不是为 3.3V 的 SD 卡准备的。

---

## 7. 当前状态与可选路线

**现状：microSD 座（3.3V）配 1.8V 的 Bank1 → 用不了；
eMMC（1.8V 合适）又不应答 CMD1 → 说明它没有挂在这条总线上（被选通电路断开，或该核心板版本没接）。**

要往下走，可选：

### 路线 A —— JTAG 直接把图像灌进 DDR（立刻可用，不改硬件，最适合开发阶段）
```bash
xsct
  connect
  targets -set -filter {name =~ "ARM*#0"}
  rst -processor
  dow -data image.bin 0x10000000      # 图像直接进 DDR
  dow MID_plt.elf
  con
```
PL 从 DDR 取图。**不需要任何存储设备、不需要文件系统**，PL / 算法调试今天就能开始。

### 路线 B —— UART 传图进 DDR（能独立运行，做演示最省事）
PS 端开一个接收循环，从 UART1（115200）收 128 KB 到 DDR（约 12 秒），
然后 PL 从 DDR 取图。不依赖 SD/eMMC，BOOT.BIN 从 QSPI 启动即可。

### 路线 C —— 先确认硬件，再决定要不要修 SD
需要人在板子边上看/量：

1. **卡座里到底有没有插卡？**（没插卡时所有命令都会超时，现象完全一样）
2. **核心板上有没有 SD/eMMC 选通的跳线帽、0Ω 或焊桥？**（丝印可能是 `SD/EMMC`、`J_MMC`、`SEL` 之类）
3. **量一下**：卡座 VDD（J8 pin4）是不是 3.3V；`VCCIO_BANK1` 到底是 1.8V 还是 3.3V。

如果 VCCIO_BANK1 其实是**可由跳线选择**的 3.3V，那把它切到 3.3V、
并在 PS7 里把 Bank1 整体配成 `LVCMOS 3.3V`，SD 卡就能用
（ENET0 / USB0 / UART1 / MIO46..53 在 3.3V 下都没问题，RTL8211F 支持 3.3V RGMII）。

### 路线 D —— 网口（lwIP）传图
板上有 RTL8211F-CG（PS_ENET0）。但笔记本没有网口，要先用 USB 网卡，且要加 lwIP，工作量最大。

---

## 8. 相关文件

- 探针代码：`csrc/MID_plt/src/main.c`（`sd_probe()` / `raw_cmd()`）
- 电平实验脚本：`sd33_test.tcl`（改 MIO 寄存器后重跑 ELF，不重新综合）
- 原理图关键区域截图：`docs/env/ACZ7015_microSD_J8.png`
- 原厂配置基线：`docs/env/_ref/ps7_linuxbase_config.txt`
