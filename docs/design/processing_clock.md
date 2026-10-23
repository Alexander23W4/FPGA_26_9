# 处理时钟与 HDMI 时钟（2026-10-17）

## 当前配置

| 时钟 | 频率 | 负责的部分 |
| --- | ---: | --- |
| `clk` | 默认 80 MHz | AXI-Lite、MM2S、图像算法、帧缓存写口、独立回传读口、S2MM、HP0 与 ILA |
| `pclk` | 25.2 MHz | 帧缓存 HDMI 读口、显示格式计算、HDMI 光栅 |
| `pclk_x5` | 126 MHz | HDMI 串行输出，仍与 pclk 来自同一 MMCM |

处理时钟由新增 `clk_wiz_proc` 生成，输入接到原 `clk_wiz_0` 的 126 MHz 缓冲输出。
这样两个 MMCM 共用板上的 `clk50M` 输入缓冲，避免同一封装时钟脚被放置两个 IBUF。
两个 MMCM 都锁定后才释放公共复位；RTL 在三个域各自同步释放本地复位。
`--fclk0` 改的是 PS FCLK，不能用它修改本项目的处理时钟。

`scripts/tcl/processing_clock.tcl` 同时处理新建工程和旧 BD 迁移；无需删除正式工程。
迁移时整组移动原处理/AXI 时钟负载，保留 pclk；不会把 DMA 留在旧像素时钟。
输入 MM2S 内存 64 位、输出 S2MM 内存 64 位、HP0 64 位，输出 AXIS 32 位均保持不变。

## 跨域处理

- BRAM 数据：双时钟存储端口，写端只能复用已被读端释放的 bank。
- 发布新帧：写端固定 bank/toggle，经过 `display_frame_cdc` 送到显示域。
  HDMI 真正在帧边界接管该 bank 后返回确认；CDC 收到通知本身不代表已接管。
  关闭显示时，等待显示端确实停止 BRAM 读取，并确认/丢弃在途发布后再复用 bank。
- 模式和透明度：保持 payload，使用 request/acknowledge 握手成组传输。
  快速更新可以合并为最新值；显示格式仍在光栅帧边界锁定，避免半帧换模式。
- HDMI 开关：OFF 必须送到显示域后才允许后续 ON；短至一个处理时钟的 OFF 也不会丢失。
- ILA：删除处理时钟直接采样 HDMI 读地址的跨域路径，改为采样同域回传读地址。
- 回传、状态和计时均已位于 clk 域，删除无必要的逐位二次同步。

`constrs/processing_cdc.xdc` 只对同步器首级放宽检查；同步器后续级仍正常计时。
对握手 payload 增加一个目的时钟周期的 `set_max_delay -datapath_only`，
未使用全时钟组 false path 隐藏其他未知跨域路径。
HDMI 慢到快的 multicycle hold 约束显式使用 `-end`，与捕获时钟对应。

## 测试和频率选择

局部实验只包含 top1 及其 RTL，未包含完整 PS/AXI IP 和板级时钟/IO 布局。

| 实验 | 结果 |
| --- | --- |
| 100 MHz 局部综合、布局、物理优化 | WNS -1.479 ns；透明度运算及去噪路径存在违例 |
| 80 MHz 局部综合、布局、布线 | WNS +0.567 ns、WHS +0.092 ns、WPWS +3.468 ns |
| 80/100/150/25 MHz 对 25.2 MHz 异频仿真 | 均通过；每组 10 输入帧、16 完整回传包，全像素比较 |
| 快速配置/半途复位 | 配置配对一致、最新值到达、复位异步断言/本域同步释放，均通过 |
| Python 回归 | 81 项，80 通过、1 跳过；包含旧/新计时元数据兼容 |
| 固件原生回归 | 通过，含 100/150 MHz 计时换算及旧硬件回退 |

局部 CDC 报告中 clk→pclk 有 39 个 CDC-15、1 个 CDC-17 Warning，均对应有确认和延迟约束的
稳定 payload；同步控制标为 CDC-3。反向 4 条路径均为 CDC-3。两个方向没有 Critical 项。
这些 Warning 保留供实现时复查，没有批量屏蔽。

80 MHz 是当前经过局部布线验证的默认候选，不是已确认的整板极限。
150 MHz 的行为仿真通过不能说明该频率能够满足 FPGA 时序。
正式全量实现后，构建脚本检查 setup/hold；负 slack 会阻止导出并发布最新 XSA/构建。
报告在正式工程目录 `implemented_timing.rpt`、`cdc_to_pixel.rpt`、`cdc_from_pixel.rpt`。

局部测试结果：`build/tests/processing_clock/`、`build/tests/processing_cdc/`。
重新运行功能仿真：

```bash
"/e/PythonVersionEnv/Python3.14.0/python.exe" scripts/tests/run_processing_cdc_checks.py
```

## 编译、烧录与 GUI

本次同时修改了 PL 和 PS，必须重建两者。仓库根目录 Git Bash 一条命令：

```bash
./scripts/build.sh zynq -n fpga_26 -H && ./scripts/build.sh app -n MID_plt -p fpga_26 -f && bash ./scripts/flash_current.sh init
```

完成后重启 GUI、刷新网页。这里没有自动对开发板烧入提频试验位流，当前板端仍是原先配置。
试验其他处理频率可在 PL 构建命令前设置 `PL_CLK_MHZ`；MMCM 实际频率必须与请求一致，
且每个候选都需重新实现、通过时序检查后重建 PS。不要只改时钟约束来假装提频。

新增只读寄存器：word `0x36` / byte `0xD8`，返回实际配置的 clk Hz。
PS 从它换算 PL 计时，元数据版本 5 的 interval/stall 字段使用微秒。
Python 同时兼容旧版 4 的 25.2 MHz ticks。旧硬件读不到频率时 PS 回退为 25.2 MHz。
这样提频后 GUI 不会把耗时错误地放大约 3.17 倍。
