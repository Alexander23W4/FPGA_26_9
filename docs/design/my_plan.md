## 当前显示功能和地址表

当前发图已改为 `GUI → 网口 → DDR → PL → S2MM → DDR → 网口 → PC`。
输出保留模式与 RGB，使用 `0x20010000–0x2004FFFF`；文件自动保存到 `E:/fpga_done_img`。
完整地址、协议和重试说明见 [network_ddr.md](network_ddr.md)。

“选择流文件夹”可循环发送目录中的 BIN，等每帧回传落盘并回读 FPGA 状态后再发送下一帧。
流模式禁用全显示；阈值和透明度更新仅在帧间写寄存器。流结果按
`E:/fpga_done_img/文件夹名/原帧名.bin`（及 PNG）覆盖保存，不添加时间或模式后缀。

已接通叠加掩膜、伪彩色热力图及掩膜透明度。
寄存器编号、实际 AXI 字节偏移、串口命令和验证方法见 [display_modes.md](display_modes.md)。
本次更改需要同时重新构建并下载 PS 和 PL；下面的统一构建下载命令仍适用。

板端输出 DDR
    ↓ PS 读取
TCP 网口
    ↓
PC 的 Python 接收程序（内存）
    ↓ 二进制数据
浏览器 Web Worker
    ↓
Canvas：GUI 处理图的黑框

## 后续方向:
上位机交互拓展方案: 

批量图片发送处理和传回  
实时视频影像的处理

fpga算法拓展:

显示模式: 显示去噪图, 显示去噪+轮廓, 显示去噪+掩膜图 


心脏两腔心、四腔心视图，并提供左心室心内膜、心外膜及左心房的人工标注。

## 基础算法:
分割掩膜叠加(可快速实现)

智能分析功能:
器官或组织分割 (CAMUS的2腔/4腔识别并分割, 这个用拓展部分1的模型实现, 直接用CAMUS训练)


## 拼图问题
hdl_out.v 只有收满 65,536 个输出像素才发布一帧；hdmi_out.v 只在 HDMI 帧边界切换到新缓存。拼图帧一旦被发布，显示端会持续扫描这块缓存；如果之后没有再收到足够像素形成并发布一张完整帧，HDMI 就会一直显示这张拼图。画面看起来卡住，实际是持续刷新同一个已完成帧。

这个只要使得ps发帧的时候不要中断, 每一帧都能够完整发完, 就不会出现这个问题
如果之后确实会出现发帧中断的问题, 那么就让不得不中断之后用axi-lite给pl发reset, 然后强制重置pl的帧缓存和帧计数

## GUI 离线演示（Git Bash）

在 Git Bash 中从仓库根目录运行这一条命令，即可启动 mock PS 服务并打开 GUI：

```bash
bash ./network/launch_gui.sh
```

脚本会检查端口；若控制端口 `127.0.0.1:5000` 和图像端口 `127.0.0.1:5001` 尚未启动，
就自动启动 mock PS，再以 `--board-ip 127.0.0.1` 打开 GUI。若 mock 已经在这两个端口
运行，则直接复用，不会重复启动。GUI 网页使用 <http://127.0.0.1:8765/>。这些端口仅在
本机回环地址监听，不需要开放 Windows 防火墙端口；若 8765 已被占用，先关闭已有 GUI
再运行启动命令。浏览器打开后，点击 **“选择BIN图像”** 即可换图。
图像处理模式下选图后自动使用真实板卡网口 5002，结果保存到 `E:/fpga_done_img`。
需要指定启动时预览的初始图片时，把路径作为第一个参数：

```bash
bash ./network/launch_gui.sh /e/camus/images/testing/patient0047/patient0047_4CH_ES.png
```

如果 Python 不在启动脚本默认位置，可通过 `PYTHON=/path/to/python.exe` 覆盖。退出时在
Git Bash 终端按 `Ctrl+C`，脚本会同时停止 mock PS 服务。mock 返回演示用的模拟掩膜和
状态，不代表 FPGA 的实际图像处理结果。

## 当前上板：GUI 单帧 HDMI 测试

以下命令在仓库根目录的 Git Bash 中执行。现在使用 GUI 发图，不再以
`pl_ctrl_test` 的三张图循环作为默认测试流程。

### 1. 原命令的问题和修复

命令名称没有过时，问题在它们调用的脚本和选择的产物：

| 原写法 / 行为 | 具体问题 | 已修改的行为 |
| --- | --- | --- |
| `build.sh zynq -n fpga_26 -H` | 已有工程只更新编译顺序、重置 synthesis run；没有显式刷新模块引用、重置生成产物。检查到的旧实现缺少 `0x10/0x14`。 | 每次刷新模块引用，禁用 IP 缓存，重新生成 BD 输出和 OOC run，关闭增量检查点，然后重新综合实现。 |
| 仅凭综合结束或 bit 文件日期判断成功 | 新顶层实现仍可能拼入旧模块网表。 | 完成实现后检查 `video_mode` 和 17 位面积保存寄存器；缺失则报 `STALE_PL`，不发布可下载产物。 |
| `build.sh app -n MID_plt -f` | `-f` 原来只重编已有平台，没有把新 XSA 导入平台；平台配置曾指向 9 月 24 日的 XSA。 | 用 `update_hw` 导入指定 XSA，检查平台和应用构建状态；应用构建前移除旧 ELF，防止软失败后误报成功。 |
| 遍历目录找到第一个 bit/ELF，或按路径排序选择 XSA | 可能选中历史产物、其他应用或其他硬件平台。 | 使用精确输出路径，归档成功产物，以成功记录指定 XSA；不再跨应用找 ELF。 |
| 固定旧日期 `BIT=build/out/...`，或失败后继续单独烧录 | 会下载旧文件；下载成功只能证明传入文件被下载。 | `flash_current.sh` 使用成功构建的归档，检查文件哈希、源码哈希和 ELF/XSA 配对。构建失败后无法回退下载旧产物。 |
| 每次 `rm -f csrc/.lock` | 锁文件不是构建缓存；Vitis 仍运行时删除它会绕过工作区互斥。 | 不常规删锁。编译前关闭占用该工作区的 Vitis；确认相关进程已退出且锁确实残留时，才手动删除。 |
| 粘贴成 `initrm -f` | `init` 和下一条命令粘连，成为非法下载模式。 | 下载脚本只接受 `init` 或 `noinit`，非法参数立即失败。 |
| PATH 优先选中 Vitis 的 `gnuwin/bin/tee.exe` | 旧版 Windows 工具与 Git Bash 输出管道混用，可能报“标准输出: No such file or directory”，终端输出停住。 | 公共脚本将 Git Bash `/usr/bin` 放在 PATH 首位；Vivado/Vitis/XSCT 仍通过明确的 `.bat` 路径调用。 |
| 在实时日志管道中用 `tr` 去掉回车 | 管道缓冲可能隐藏启动信息，让终端停留在 `Archive dir`。 | 直接用 Git Bash 的 `tee` 实时输出；成功标记兼容 CRLF，并在输入校验和工具启动前打印进度。 |
| 编译前后校验 Vitis 自动重写的根 `CMakeLists.txt` 或 `compile_commands.json` | CMake 配置及编辑器编译命令清单会正常生成，PS 编译成功后仍误报源码变化。 | 编译期间校验 C/H、`UserConfig.cmake`、链接脚本等用户文件；编译完成后记录最终 `CMakeLists.txt`，下载前仍校验。`compile_commands.json` 是生成物，始终排除出构建输入校验。 |

禁用缓存采用 Vivado 2023.2 的
[官方 `config_ip_cache` 命令](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/config_ip_cache)。

### 2. 一条命令完成 PL、PS 构建和 JTAG 下载

先关闭占用此工程的 Vivado/Vitis，以及占用板卡串口的 GUI、终端。
如果日志出现 `Failed to delete one or more files in run directory`，先停止当前构建，
关闭打开此工程的 Vivado/Vitis 窗口，释放目录占用后重新运行。
开发板连接并上电后执行：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f && bash ./scripts/flash_current.sh init
```

`&&` 使任何一步失败都停止后续步骤。正常日志应依次出现：

```text
BD_REFRESH_OK
PL_REGISTERS_OK
BUILD_ZYNQ_OK
BUILD_PS_OK
[flashall] PL programmed
FLASH_ALL_OK
```

这些标记后面可能带参数。`PL_REGISTERS_OK` 检查实现网表包含相应寄存器，
不替代上板功能测试。

### 3. 尚未连接开发板时：先完成编译，之后只下载

先执行：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f
```

拿到板卡并上电后，只需：

```bash
bash ./scripts/flash_current.sh init
```

脚本会打印本次采用的 bit 和 ELF 归档路径。无需填写旧的日期目录或 `BIT`。
源码在构建后发生变化、输出文件被替换，或 ELF 使用的 XSA 不匹配时，脚本会停止。
只有同次上电已经成功执行过初始化时，才可把 `init` 改成 `noinit`。

只有 C 源码改动而 PL 没改时，可以执行：

```bash
./scripts/build.sh app -n MID_plt -p fpga_26 && bash ./scripts/flash_current.sh init
```

此命令复用成功记录中的同一份 XSA。现在首次采用修复后的流程，必须先执行一次
上面的 PL + PS 完整构建，建立新的成功记录。

`-H` 配置 HP0/VDMA 路径；它不负责清缓存。`-f` 用于 PS 平台强制更新及重建。
这次 S2MM 连接会自动迁移到已有 BD。其他尚未提供迁移的建工程 Tcl 结构修改，需给 `zynq`
加 `-R` 从 Tcl 重建工程；这会删除原 Vivado 工程目录，GUI 中未导出的工程改动应先保存。
普通 RTL 修改直接使用上面的命令即可。

### 4. GUI 发图和回读

```bash
bash ./network/launch_gui.sh
```

先设置“FPGA输出显示模式”，选择 **256×256、8-bit 灰度、无文件头、恰好 65,536 字节的 `.bin`**
后自动发送；“阈值更新”或“掩膜透明度更新”成功后自动重发当前原图。切显示模式复用 PL 缓存，全显示每收完并保存
一张再切下一模式。当前路径为
`GUI → TCP → 输入DDR → VDMA → PL`；输出同时走 HDMI 和
`back_stream → AXI DMA S2MM → 输出DDR → TCP → PC`。
每次仅发送一帧，遇到反压暂停，完整发完后 VDMA 自动停止。
GUI 发图不再经过 eMMC；PL 发完直接空闲，PC 保存 BIN 和 PNG 后确认释放 PS 输出 DDR。

等待图像处理完成后点击“请求FPGA状态”，查看标为“FPGA回读”的模式和面积。
结果目录为 `E:/fpga_done_img`。板端 `192.168.1.10:5002`，PC 网卡应在同一网段。
启动脚本同时提供 mock 网络演示，普通网页统计和预览不能作为 HDMI 实际输出的证据。
串口默认 COM7；端口必须与板卡实际端口一致。`net_recv.ps1` 已删除，不再执行旧接收命令。

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
