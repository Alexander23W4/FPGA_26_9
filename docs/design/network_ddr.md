# GUI 单帧网口往返

## 数据路径

```text
GUI 选择 256×256×8-bit BIN
  → TCP 5002 → PS 直接写输入 DDR
  → VDMA MM2S（64 位）→ axi2px → PL 图像处理
  → out_arr ─→ hdmi_out → HDMI 持续刷新
            └→ back_stream（每像素一次 32 位握手）
              → AXI DMA S2MM（64 位内存接口）→ 输出 DDR
              → TCP → PC 保存 BIN + PNG → SAVED 确认
              → PS 写 BACK_RECEIVE → PL 恢复空闲 → DONE
```

“传输给FPGA”只走这条网口路径，不调用 eMMC 的 E/A/D 命令。
输入完整收齐并通过 CRC 后才启动 DMA；先准备 S2MM，再启动 MM2S。
MM2S 只发送一帧，遇到 PL 反压时等待，完整发送后由硬件停止。
PS 同时检查 MM2S 已完成且停止、S2MM 接收完成及实际字节数、PL 回传状态。

## 地址与格式

| 用途 | 地址范围 | 大小 / 格式 |
| --- | --- | --- |
| 输入 DDR | `0x20000000–0x2000FFFF` | 65,536 字节；逐行 256×256 灰度，无文件头 |
| 输出 DDR | `0x20010000–0x2004FFFF` | 262,144 字节；65,536 个 `{mode,R,G,B}` 32 位字 |
| VDMA 控制 | `0x43000000` | 原 MM2S 通道 |
| PL 控制 | `0x44000000` | 寄存器编号需乘 4 |
| AXI DMA 控制 | `0x45000000` | 独立 AXI DMA，仅启用 simple S2MM |
| BACK_RECEIVE | `0x440000C0` | 编号 0x30；写 bit0=1 触发一次确认 |
| BACK_STATUS | `0x440000C4` | 编号 0x31；只读：bit0 busy、bit1 waiting_ack、bit2 overflow |

输入 `.bin` 必须恰好 65,536 字节。RAW BIN 没有尺寸元数据，程序固定按 256 行、
每行 256 个无符号 8 位像素解释，不自动缩放或截断。

回传 `.bin` 在小端 DDR/文件中的字节顺序为 **B、G、R、mode**，每像素四字节。
mode 为 0～4，整帧保持一致。输出 PNG 为普通 256×256 RGB 图片，方便直接查看。
S2MM 的 TLAST 表示整帧包结束；输入 VDMA 的 TLAST 表示行尾，两者语义不同。
DMA 的长度寄存器配置为 23 位，能够容纳 256 KiB，不能沿用默认 14 位长度。
长度写入是启动接收的最后一步，完成后读取实际接收字节数，依据
[AMD S2MM_LENGTH 定义](https://docs.amd.com/r/en-US/pg021_axi_dma/S2MM_LENGTH-S2MM-DMA-Buffer-Length-Register-Offset-58h)。

## 使用

这次同时修改了 BD、RTL、PS 和 GUI，需要完整重新构建和下载。在仓库根目录 Git Bash：

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

选择图像处理模式，选择 BIN，设置显示模式和阈值，点击“传输给FPGA”。成功提示出现后，
结果在 **`E:/fpga_done_img`**：每次一份原始 `.bin` 和一张 `.png`，文件名包含原图名、
显示模式、时间和任务号。无需另开 PC 接收脚本。

文件名格式为 `<原图名>_<denoise|contour|mask|overlay|heat>_<年月日_时分秒_微秒>_<8位十六进制任务号>.bin`，
PNG 使用相同主文件名。GUI 根据本次任务返回的准确路径检查 BIN，不扫描同名历史结果。
回传 BIN 为 256×256×4 字节，每像素按 B、G、R、mode 排列；它不能按输入的 8-bit 灰度 BIN 加载。

“全显示”发送同一张原图五次，模式依次为 0～4，显示原图及五张处理图，共六张。
每轮顺序为：串口 V 命令更新并核对 AXI-Lite 模式 → 网口发原图 → 回传 BIN 落盘校验 →
SAVED → PS 写 receive_done → DONE → 从 BIN 解码并更新 GUI，再开始下一轮。
每完成一轮，`/api/state` 就提供该模式的处理图，网页轮询后逐张显示。
单独选择模式 0～4 时仅执行一轮，在原图右侧显示对应的回传图。
选择新原图会清空旧处理图，状态回读保留“全显示”选择。

启动脚本保留本机 5000/5001 的模拟预览；真实图像传输独立使用板端 5002。
网页模拟预览不作为板端处理结果。检查回传 PNG 和 HDMI 以确认实际输出。
板端 IP 若需调整，需同时修改 `net_frame.c` 中的地址与 GUI 的 `--transfer-ip`；
启动脚本读取 `FPGA_IP` 环境变量作为 GUI 的真实传输目标。

## 完成、重试和错误

- TCP 头与输入、输出长度都进行校验；两端使用 CRC32 检查完整图像数据。
- 同一时间只处理一帧。全显示的五轮也串行执行；GUI 在整个任务期间锁住重复发送、选图及参数修改，
  并串行处理 UART 参数操作。
  PS 在任务未完成时拒绝修改参数或启动旧 eMMC 测试，保护 DDR 和帧配置。
- PC 写临时文件，flush/fsync 后改名；重新打开对应 BIN，核对 CRC、长度及每像素模式，
  并确认 PNG 存在后才发送 SAVED。回传模式必须与本轮请求模式一致。
  PS 仅在任务号、长度、CRC、模式均匹配时写 BACK_RECEIVE。
- PS 等待 BACK_STATUS.busy 清零才回复 DONE。GUI 收到匹配的 DONE 才报告成功。
- 网络断开后，GUI 自动尝试恢复同一任务；上传尚未收齐时重新上传，处理已开始时等待原任务，
  输出已生成时重新读取同一输出。DONE 丢失可重新查询，不重复启动 PL 或重复硬件 ACK。
- 磁盘保存失败不会 ACK。修复磁盘问题后，在同一个 GUI 进程中以**相同显示模式重新发送同一张图**可恢复；
  全显示会保留已完成的结果，从失败的模式继续，不重复已完成的轮次。
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
| 2 | RESULT | 262144 | 输出 BGRmode 数据 | mode |
| 3 | SAVED | 262144 | 无 | mode |
| 4 | DONE | 0 | 无 | mode |
| 5 | ERROR | 文本字节数 | UTF-8 错误文本 | 1 需上传、2 失败、3 忙 |
| 6 | RESUME | 0 | 无 | 0 |

SAVED/DONE 携带输出 CRC。RESUME 的 CRC 为 0；ERROR 不使用 CRC。

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
落盘后确认、回传图加载、原图保真、模式不符拒收及全显示保存失败后的继续处理。
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
