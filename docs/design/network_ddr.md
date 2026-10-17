# GUI 单帧与流网口往返

## 连续流优化（2026-10-17）

流模式现在由浏览器 Web Worker 独立收发；主线程只绘制 Canvas，不编码预览 PNG。
原图仅上传一次，直接从本地灰度 BIN 绘制。回传保持每像素 B、G、R、mode 四字节。
PS 将整帧复制到 TCP 发送缓冲后释放输出 DDR；PC 收齐 RGBA 和随帧状态、校验通过就发送下一帧。
流模式不发送 RECEIVED，不等待 DONE，也不等待 GUI 绘制。TCP 自身仍负责可靠传输。
流模式完全在内存中收发和显示，不保存 BIN、不编码或保存 PNG，也没有磁盘保存队列。
浏览器渲染跟不上时只绘制最新的完整帧，收发不等待绘制。原流从本地 BIN 直接绘制。
单图及“全显示”仍使用落盘后 `SAVED` / `DONE`，保留失败重试和保存成功确认。

正常连续收发复用一个 TCP 连接，断线后仍按 job_id 恢复；连接设置 TCP_NODELAY。
新连接先以无图像负载的 HELLO_FAST 确认 PS 支持协议版本 2，防止把新协议图像发给旧固件。
随帧状态包含七个寄存器的快照并纳入同一 CRC，不再逐帧开串口发送 R。
阈值/透明度写入与手动“请求FPGA状态”保留 UART，在流的帧间暂停处执行。
PS CRC32 使用 1 KiB 常量查表，校验值保持 IEEE CRC32，与 Python binascii.crc32 一致；
同时去掉正常逐帧 UART 日志，避免阻塞网口轮询。

处理模式的周期轮询只取 `/api/network/state` 元数据。初始页面/选图时才取原图，
处理图随实际任务返回；流模式直接用回传 BIN 绘制，轮询不会重复编码或发送图像。

本次修改了 PL 像素格式和模式锁存寄存器，需要重新综合 PL、构建 PS 并下载。仓库根目录 Git Bash：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f && bash ./scripts/flash_current.sh init
```

然后停止原 GUI、重新运行 `bash ./network/launch_gui.sh` 并刷新网页。
本地 ARM 编译链接检查只生成测试 ELF，不替代上述正式构建及下载。

## 数据路径

```text
GUI 选择 256×256×8-bit BIN
  → TCP 5002 → PS 直接写输入 DDR
  → VDMA MM2S（64 位）→ axi2px → PL 图像处理
  → out_arr ─→ hdmi_out → HDMI 持续刷新
            └→ back_stream（每像素一次 32 位握手）
              → AXI DMA S2MM（64 位内存接口）→ 输出 DDR
              → TCP → PC 保存 BIN + PNG → SAVED 确认
              → PS 释放输出 DDR 所有权 → DONE
```

图像处理模式下选择 BIN 后自动走这条网口路径，不调用 eMMC 的 E/A/D 命令。
输入完整收齐并通过 CRC 后才启动 DMA；先准备 S2MM，再启动 MM2S。
MM2S 只发送一帧，遇到 PL 反压时等待，完整发送后由硬件停止。
PS 同时检查 MM2S 已完成且停止、S2MM 接收完成及实际字节数、PL 回传状态。

## 地址与格式

| 用途 | 地址范围 | 大小 / 格式 |
| --- | --- | --- |
| 输入 DDR | `0x20000000–0x2000FFFF` | 65,536 字节；逐行 256×256 灰度，无文件头 |
| 输出 DDR | `0x20010000–0x2004FFFF` | 262,144 字节；65,536 个 `{255,B,G,R}` 32 位字（内存字节 RGBA） |
| VDMA 控制 | `0x43000000` | 原 MM2S 通道 |
| PL 控制 | `0x44000000` | 寄存器编号需乘 4 |
| AXI DMA 控制 | `0x45000000` | 独立 AXI DMA，仅启用 simple S2MM |
| 原反馈地址 | `0x440000C0` | 已移除，读写返回 SLVERR |
| BACK_STATUS | `0x440000C4` | 编号 0x31；只读：bit0 busy、bit1 固定 0、bit2 overflow |
| BACK_FRAME_MODE | `0x440000C8` | 编号 0x32；只读：PL 在回传 SOF 锁存的真实显示模式 |

输入 `.bin` 必须恰好 65,536 字节。RAW BIN 没有尺寸元数据，程序固定按 256 行、
每行 256 个无符号 8 位像素解释，不自动缩放或截断。

回传 `.bin` 在小端 DDR/文件中的字节顺序为 **R、G、B、255**，每像素四字节。
Alpha 固定 255。模式由 PL 在 SOF 锁存，经独立只读寄存器交给 PS，放在回传消息头中。输出 PNG 为普通 256×256 RGB 图片，方便直接查看。
S2MM 的 TLAST 表示整帧包结束；输入 VDMA 的 TLAST 表示行尾，两者语义不同。
DMA 的长度寄存器配置为 23 位，能够容纳 256 KiB，不能沿用默认 14 位长度。
长度写入是启动接收的最后一步，完成后读取实际接收字节数，依据
[AMD S2MM_LENGTH 定义](https://docs.amd.com/r/en-US/pg021_axi_dma/S2MM_LENGTH-S2MM-DMA-Buffer-Length-Register-Offset-58h)。

## 使用

首次部署或 PL 有改动时，需要完整重新构建和下载。在仓库根目录 Git Bash：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f && bash ./scripts/flash_current.sh init
```

现有工程的构建准备步骤会补入 S2MM 和 HP0 连接，无需手工在 BD 中重复添加。
本机 GUI 启动命令保持不变：

```bash
bash ./network/launch_gui.sh
```

板端固定地址 **192.168.1.10/24，TCP 5002**。PC 有线网卡需在同一网段，例如
192.168.1.20/24，且没有其他设备占用板端 IP。启动日志应有
`[network] DDR frame TCP server 192.168.1.10:5002`。
参数配置与“请求FPGA状态”继续用原串口，默认 COM7。

选择图像处理模式，设置显示模式，选择 BIN 后自动上传并回传。点击“阈值更新”或
“掩膜透明度更新”会先核对对应寄存器写入，再自动重发当前原图处理。
未选择原图时仅更新参数；写入失败不重发。传输按钮已移除，成功不弹窗，出错才弹窗。
结果在 **`E:/fpga_done_img`**：每次一份原始 `.bin` 和一张 `.png`，文件名包含原图名、
显示模式、时间和任务号。无需另开 PC 接收脚本。

文件名格式为 `<原图名>_<denoise|contour|mask|overlay|heat>_<年月日_时分秒_微秒>_<8位十六进制任务号>.bin`，
PNG 使用相同主文件名。GUI 根据本次任务返回的准确路径检查 BIN，不扫描同名历史结果。
回传 BIN 为 256×256×4 字节，每像素按 R、G、B、255 排列；它不能按输入的 8-bit 灰度 BIN 加载。

“全显示”只上传原图一次，先接收新图在当前 PL 模式下的结果，再逐一请求剩余模式，
显示原图及五张处理图。每张都先完成回传、落盘校验、SAVED、DONE，才切换下一模式。
切换显示模式通过 TCP RENDER 复用 PL 当前缓存，不重传原图、不重跑去噪/阈值算法。
PS 先启动 S2MM，再写模式寄存器；PL 在帧边界更新配置并回传完整图像。
请求同一模式时，PS 可直接返回当前输出 DDR 的完整结果。尚无图像时只配置模式。
每完成一轮，任务响应就提供该模式的处理图，网页据此逐张显示。
单独选择模式 0～4 时在原图右侧显示对应的回传图。
选择新原图会清空旧处理图，状态回读保留“全显示”选择。

启动脚本保留本机 5000/5001 的模拟预览；真实图像传输独立使用板端 5002。
网页模拟预览不作为板端处理结果。检查回传 PNG 和 HDMI 以确认实际输出。
板端 IP 若需调整，需同时修改 `net_frame.c` 中的地址与 GUI 的 `--transfer-ip`；
启动脚本读取 `FPGA_IP` 环境变量作为 GUI 的真实传输目标。

## 完成、重试和错误

### 流文件夹

“选择流文件夹”读取所选目录及子目录中的 `.bin`，按带数字的文件名顺序循环，
每个文件仍须为 256×256×8-bit、65,536 字节。非 BIN 文件忽略；不合规格的 BIN 会在启动前报错。
收发顺序为：本地读取 BIN → 上传一帧 → 收齐本次 BIN 与状态、CRC 校验 →
下一帧。所有文件发完后从头继续。预览绘制独立执行，不是下一帧的前置条件；流不保存结果文件。

- 流模式禁用“全显示”；从全显示切入流时使用模式 0。
- 阈值、透明度更新排队到当前帧完成后写寄存器，不额外发图；显示模式在下一帧生效。
- 左下角只显示流文件夹名称。右侧保留上一次确认的回传，直到新的 BIN 成功接收。
- 每一轮都实际启动新的上传/处理/回传任务，即使文件名、输入数据及全部参数相同。
  页面按新任务和结果版本更新，文件已经存在不会触发显示。
- 流结果只显示在处理流黑框，不写入 `E:/fpga_done_img`，也不会读取已有同名文件。
- 运行时按钮显示“停止流”；停止后等当前帧完整完成，不再发下一帧。
  回传失败会停止循环并提示错误；状态随图像一并校验。

### 单帧任务的校验与恢复

- TCP 头与输入、输出长度都进行校验；两端使用 CRC32 检查完整图像数据。
- 同一时间只处理一帧。全显示的五轮也串行执行；GUI 在整个任务期间锁住重复发送、选图及参数修改，
  并串行处理 UART 参数操作。
  PS 在任务未完成时拒绝修改参数或启动旧 eMMC 测试，保护 DDR 和帧配置。
- PC 写临时文件，flush/fsync 后改名；重新打开对应 BIN，核对 CRC、长度及每像素模式，
  并确认 PNG 存在后才发送 SAVED。回传模式必须与本轮请求模式一致。
  PS 仅在任务号、长度、CRC、模式均匹配时释放 DDR 并回复 DONE。
- PL 在最后一拍 AXI 握手后直接空闲，不再等待 PS 确认。PS 接收结果时检查 busy 清零，
  并继续保管输出 DDR，直到 PC 的 SAVED 到达。
- 网络断开后，GUI 自动尝试恢复同一任务；上传尚未收齐时重新上传，处理已开始时等待原任务，
  输出已生成时重新读取同一输出。DONE 丢失可重新查询，不重复启动 PL。
- 回传超时则立即结束该任务，不再自动 RESUME。默认每次上传/重绘的网络事务总时限为 60 秒，
  包括分片接收与断线重试；持续收到零碎数据也不会无限延长等待。
  GUI 只弹出一次超时提示，清空状态文字、单帧及全显示的等待记录并恢复操作。
  下一次操作使用新任务号；已选图像需要重新上传后再使用模式重绘，避免沿用超时任务的状态。
  之前已完整保存的 BIN/PNG 不删除。
- 超时清理还会通过新 TCP 连接发送一次单向 CANCEL，不等待确认或旧图回传。
  PS 丢弃该任务的待发结果和 PC 确认等待；若 DMA 仍在运行，则先收完当前硬件数据包，
  随后直接空闲，不向 PC 发送迟到结果。取消按任务号匹配，迟到取消不会清掉新任务。
  网络已断开时取消通知可能无法送达，但 PC 仍立即删除本地等待记录。
  本次新增的板端取消支持需要重新构建和下载 PS 应用，同时重启 GUI。
- 磁盘保存失败不会 ACK。修复磁盘问题后，在同一个 GUI 进程中以**相同显示模式重新发送同一张图**可恢复；
  全显示会保留已完成的结果，从失败的模式继续，不重复已完成的轮次。
  上传任务可重新选择同一 BIN；纯模式切换任务则重新选择失败时的显示模式。
  未确认前发送不同图或切换任务模式会被拒绝。任务恢复信息保存在 GUI 进程内，等待期间不要重启 GUI。
- 溢出、短包、DMA 错误或 PL 超时会使任务进入故障态，保留错误，要求复位并重新下载后再试。
  不自动 ACK 一张不完整的图片。普通网络中断和磁盘错误可按上述流程恢复。
- HDMI 不接受回传分支反压。回传 FIFO 有限（默认 2048 像素），长期 DDR 反压仍可能溢出；
  此时返回错误，不能把短包当作完整图片。

## 网络协议

每个头为 6 个大端 u32，共 24 字节：
`magic=0x48434631("HCF1"), type, job_id, length, crc32, extra`。
长度字段依消息类型解释，不能统一按 length 继续读 payload：

| type | 消息 | length | 后续 payload | extra |
| --- | --- | --- | --- | --- |
| 1 | UPLOAD | 65536 | 输入灰度图 | 0 |
| 2 | 旧 RESULT（主机兼容旧固件） | 262144 | 旧 BGRmode 数据 | mode |
| 3 | SAVED | 262144 | 无 | mode |
| 4 | DONE | 0 | 无 | mode |
| 5 | ERROR | 文本字节数 | UTF-8 错误文本 | 1 需上传、2 失败、3 忙 |
| 6 | RESUME | 0 | 无 | 0 |
| 7 | RENDER | 0 | 无 | 请求的 mode 0～4 |
| 8 | CONFIGURED | 0 | 无 | 已配置的 mode，无图像时回复 |
| 9 | CANCEL | 0 | 无 | 0；单向取消对应 job，不等待回复 |
| 10 | UPLOAD_FAST | 65536 | 输入灰度 BIN | 0 |
| 11 | RESULT_FAST | 262188 | 44 字节状态/耗时 + 262144 字节 RGBA | mode |
| 13 | RENDER_FAST | 0 | 无 | 请求 mode 0～4 |
| 14 | HELLO_FAST | 0 | 无；新连接能力查询 | 0 |
| 15 | FAST_READY | 0 | 无；支持 RGBA 无应用 ACK 流协议 | 协议版本 2 |
| 16 | RESULT_RGBA | 262144 | 单图/全显示 RGBA，落盘后仍用 SAVED/DONE | mode |

RESULT_FAST 的 44 字节状态为十一个大端 u32：
`version=2, MODE, CMD_REG, FRAME_VIDEO_MODE, STATUS, DATA_REG, LESION, MASK_TRANSP, receive_us, setup_us, pl_to_ddr_us`。
CRC 覆盖状态与 RGBA 的拼接字节。接收、准备和 PL 到 DDR 耗时来自 A9 全局计时器。
PS 使用 TCP_WRITE_FLAG_COPY；整帧复制成功后 TCP 自己持有发送/重传数据，DDR 才可复用。
图模式继续等待 SAVED/DONE，流模式收齐并校验后直接开始下一帧；绘制只保留最新完整帧。

SAVED/DONE 携带输出 CRC。RESUME/RENDER/CONFIGURED/CANCEL 的 CRC 为 0；ERROR 不使用 CRC。

## 本地验证

```bash
python -m unittest discover -s network/host -p 'test_*.py'
python scripts/tests/run_firmware_network_checks.py
python scripts/tests/check_network_app_link.py
python scripts/tests/run_display_checks.py
```

另有 `scripts/tests/test_network_bd.tcl` 在 `build/tests/network_bd` 创建临时 BD，检查
连接、实际接口位宽、长度配置、控制地址及重复迁移。它只创建、验证 BD，不运行综合。
C 本地测试执行真实 `net_frame.c` / `drv_s2mm.c`，以模型替代硬件和 lwIP 边界；
GUI 测试执行真实页面脚本、HTTP 处理及 TCP 客户端，覆盖五个单独模式、全显示顺序、
选图自动上传、阈值更新重发、模式切换不上传、落盘后确认、回传图加载、
原图保真、模式不符拒收及全显示保存失败后的继续处理。
ARM 检查使用已安装 BSP 编译链接至 `build/tests/network_app`，不发布测试 ELF。
这些检查不替代完整布局布线、时序报告及真实板卡网络往返测试。

2026-10-16 已完成的硬件与 PS 检查：

| 检查 | 结果 |
| --- | --- |
| 临时 BD 创建、重复迁移、控制地址和 DMA/HP0 64 位端口 | `NETWORK_BD_OK`，日志 `build/network_bd_check.log` |
| 官方 AXI DMA 模型，32 位流转 64 位内存接口，AW/W 独立等待 | 65,536 像素、262,144 字节逐字节一致 |
| 官方 DMA 模型，提前 TLAST 的 1,023 像素短包 | 实际长度 4,092 字节，供 PS 严格拒绝 |
| 真实 PS C 收包状态机与 S2MM 驱动，模型代替外设 | 分包、CRC、断线恢复、重复 ACK、短包拒绝通过 |
| 实际 ARM 编译器和 BSP/lwIP 链接 | 15 个 C 文件成功，应用最高地址约 5 MiB，远低于图像缓存 |
| 六组原有 RTL 仿真及新增 BACK_STATUS 回读 | 全部通过 |
| 构建脚本的离线回归 | 16 项通过 |

官方 DMA 仿真脚本为 `scripts/tests/test_s2mm_dma.tcl`，测试顶层为
`sim/tb/tb_s2mm_dma.sv`。通过标记 `S2MM_DMA_OK` 在 `build/s2mm_dma_check.log`。
网口客户端与 GUI 原单帧路径通过过 24 项本地测试。GUI 或多模式流程修改后，应重新运行
host 测试，以确认当前按钮、参数设置、回传和文件保存的完整行为。

耗时估算和测量边界见 [stream_latency.md](stream_latency.md)。
