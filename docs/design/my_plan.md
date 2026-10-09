## GUI 离线演示（Git Bash）

在 Git Bash 中从仓库根目录运行这一条命令，即可启动 mock PS 服务并打开 GUI：

```bash
bash ./network/launch_gui.sh
```

脚本会检查端口；若控制端口 `127.0.0.1:5000` 和图像端口 `127.0.0.1:5001` 尚未启动，
就自动启动 mock PS，再以 `--board-ip 127.0.0.1` 打开 GUI。若 mock 已经在这两个端口
运行，则直接复用，不会重复启动。GUI 网页使用 <http://127.0.0.1:8765/>。这些端口仅在
本机回环地址监听，不需要开放 Windows 防火墙端口；若 8765 已被占用，先关闭已有 GUI
再运行启动命令。浏览器打开后，点击
**“选择本地图像”** 即可通过文件资源管理器换图；点击 **“上传当前图像”** 会把当前图像
发给 mock 服务。需要指定启动时预览的初始图片时，把路径作为第一个参数：

```bash
bash ./network/launch_gui.sh /e/camus/images/testing/patient0047/patient0047_4CH_ES.png
```

如果 Python 不在启动脚本默认位置，可通过 `PYTHON=/path/to/python.exe` 覆盖。退出时在
Git Bash 终端按 `Ctrl+C`，脚本会同时停止 mock PS 服务。mock 返回演示用的模拟掩膜和
状态，不代表 FPGA 的实际图像处理结果。

## 当前上板：三张图循环 HDMI 测试

以下命令均在仓库根目录的 Git Bash 中执行。当前通过完整实现的位流是：

```text
build/out/2026-10-01_120634_c10e018-dirty/system_wrapper.bit
```

以后重新跑 `zynq` 构建后，必须把下面 `BIT` 改为该次构建输出的最新
`system_wrapper.bit`；不要再使用旧的 `2026-09-26` 位流。

### 1. 构建

PL 有 RTL、BD 或约束改动时，先完整重建：

```bash
./scripts/build.sh zynq -n fpga_26 -H -R
```

PS 程序每次改动后都要重新构建：

```bash
rm -f csrc/.lock
./scripts/build.sh app -n MID_plt -f
```

### 2. JTAG 下载并运行

首次上电、断电重上电后，或 DDR 状态不确定时，使用 `init`。它会初始化
PS/DDR，配置 PL，随后执行 `ps7_post_config` 并下载 ELF：

```bash
BIT="build/out/2026-10-01_120634_c10e018-dirty/system_wrapper.bit"

/e/Xilinx/Vitis/2023.2/bin/xsct.bat "$(cygpath -w scripts/tcl/flash_all.tcl)" \
  "$(cygpath -w "$BIT")" \
  "$(cygpath -w csrc/MID_plt/build/MID_plt.elf)" \
  "$(cygpath -w csrc/fpga_26/hw/sdt/ps7_init.tcl)" init
```

同一次上电期间，仅在已经成功执行过一次 `init` 后重新下载 bit/ELF 时，才可用
`noinit`：

```bash
/e/Xilinx/Vitis/2023.2/bin/xsct.bat "$(cygpath -w scripts/tcl/flash_all.tcl)" \
  "$(cygpath -w "$BIT")" \
  "$(cygpath -w csrc/MID_plt/build/MID_plt.elf)" \
  "$(cygpath -w csrc/fpga_26/hw/sdt/ps7_init.tcl)" noinit
```

### 3. 准备 eMMC 图片

`pl_ctrl_test` 按名称查找 `iceberg`、`lofoten`、`gb200`。三份文件必须都是
**256 x 256、8-bit 灰度、无文件头的 raw `.bin`**，每份恰好 65536 字节。串口脚本
默认使用 `COM7`；端口不同就把下面的 `COM7` 改成实际端口。运行任何一个脚本前，
先关闭占用该串口的串口终端。

若要替换已有目录中的图片，先清空目录（这会删除已登记的图片）：

```bash
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_clear.ps1)" -Port COM7
```

依次上传三张图。每条命令都应以 `RESULT: VERIFY OK` 结束：

```bash
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_add.ps1)" -File D:/test_img/iceberg.bin -Port COM7
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_add.ps1)" -File D:/test_img/lofoten.bin -Port COM7
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_add.ps1)" -File D:/test_img/gb200.bin -Port COM7
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_list.ps1)" -Port COM7
```

目录应恰好列出三项，名称为 `iceberg`、`lofoten`、`gb200`，每项 `bytes=65536`、
`w x h=256 x 256`、`bpp=1`。

### 4. 运行 HDMI 循环测试

```bash
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/run_test.ps1)" -Test pl_ctrl_test -Port COM7
```

程序会反复执行 `eMMC -> DDR -> VDMA MM2S -> AXI-Stream -> PL -> HDMI`，每张图显示
约 10 秒。串口会显示当前图片、DDR 载入地址和 VDMA 状态。`pl_ctrl_test` 是无限循环；
按 `Ctrl+C` 只能停止 PC 端串口输出，要停止板端循环则重新下载 ELF。

`net_recv.ps1` 已从项目中删除：当前数据路径直接输出 HDMI，不经过 PC 网络接收端，
不要执行旧的“笔记本开接收端”命令。

###
一定要用上的: 
比较输出(python), ILA(debug) 整个先把功能打通
用 verilator
看 vivado reports, 加性能计数器, 看怎么样能够提升性能

                  视频输入
                     │
                     ▼
              ┌─────────────┐
              │ Golden Model │  ← Python/C/OpenCV
              └──────┬──────┘
                     │ reference
                     ▼
┌──────────────────────────────────────────┐
│              RTL / HLS IP                │
│                                          │
│ AXI-Stream → Video Processing → AXI      │
│                     │                    │
└─────────────────────┼────────────────────┘
                      │
                 比较输出
                      │
                      ▼
                 PASS / FAIL


          ┌──────────────────────┐
          │ Vivado Simulation     │
          │ SV Testbench          │
          └──────────────────────┘

          ┌──────────────────────┐
          │ ILA                  │
          │ 上板实时 Debug        │
          └──────────────────────┘

          ┌──────────────────────┐
          │ Vivado Reports       │
          │ Timing / Utilization │
          │ Power                │
          └──────────────────────┘

###
AXI-Stream
    ↓
Line Buffer
    ↓
3×3 Sliding Window
    ↓
Gaussian

#	要做的	说明
1	打开 PS 的 S_AXI_HP0	            PL 作为 AXI Master 读 DDR 的唯一入口。不通它，PL 根本看不到 DDR
2	加 AXI SmartConnect	        把 VDMA 的内存读口接到 HP0 上。注意 HP0 是 64 位，位宽要对上（VDMA 设 64 位，或让 SmartConnect 转换）
3	加 AXI VDMA（只要 MM2S）	干"把 DDR 里的一块内存按行搬到 AXI-Stream"这件事
4	接时钟和复位	        FCLK_CLK0 → m_axi_mm2s_aclk 和 s_axi_lite_aclk；peripheral_aresetn → 两个 aresetn。复位不接 VDMA 一动不动
5	给 VDMA 的 S_AXI_LITE 分配地址	    落在 PS 的 M_AXI_GP0 空间里，PS 才能用寄存器配它
6	M_AXIS_MM2S 必须接上消费者	    接你自己的图像处理 RTL。悬空的话 VDMA 会背压停住，帧指针不动 —— 这个现象很容易被误判成"没配好"


首先写一个最简单的收发

ps读.bin文件, 然后传给DDR

pl从ddr里面读取图像, 然后直接用HDMI输出给电脑


          DDR
            │
            │ 输入帧
            ▼
    AXI4-Stream
            │
            ▼
    ┌──────────────┐
    │ HLS Denoise  │
    │ 3×3 Gaussian │
    └──────┬───────┘
          │
          │ AXI4-Stream
          ▼
    ┌──────────────┐
    │ Frame Buffer │
    │              │
    │  Buffer A    │◄──── 写入
    │  Buffer B    │
    └──────┬───────┘
          │
          │ 读取
          ▼
    HDMI Controller
          │
    pixel/hs/vs/de
          │
          ▼
          HDMI


PC
 ↓
Ethernet
 ↓
PS
 ↓
DDR
 ↓
AXI VDMA MM2S
 ↓
AXI-Stream
 ↓
denose
 ↓
AXI-Stream
 ↓
output frame buffer
 ↓
HDMI controller
 ↓
HDMI
 ↓
PC


  PS / ARM
AXI Master
    │
    │ AXI-Lite
    ↓
Image Controller
AXI-Lite Slave
    │
  CMD_REG
  STATUS_REG


Vivado Block Design 中加入 PS7
连接 PS7 的 S_AXI_HP0
加入 AXI SmartConnect
加入 AXI VDMA，只启用 MM2S
配置 VDMA 的 AXI4-Stream 输出宽度
加入 AXI4-Stream FIFO 或异步 FIFO

实现 640×480 视频时序
实现 256×256 图像居中显示
实现 16 位像素到 RGB 输出的格式转换
实现 TMDS 编码
使用 OSERDESE2 串行化
通过 OBUFDS 输出到 HDMI_2
添加 HDMI 时钟和差分引脚约束
用 ILA 观察 VDMA 输出和视频流 哪些是配置, 哪些是rtl实现
