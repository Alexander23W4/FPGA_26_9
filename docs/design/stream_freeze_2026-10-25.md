# 图像流运行数秒后卡死：PS 网口堆内存竞争

## 现场证据

2026-10-25，用户确认现场来自图像处理模式。串口 `R` 无响应，TCP 5002 无响应；JTAG 可以连接。短暂停止 A9 核 0 后读到：

```text
PC       0x00108274  Xil_DataAbortHandler（默认异常处理死循环）
DFSR     0x00000005
DFAR     0xFF4C4C4C
异常栈保存的返回地址 0x0010CE0C
对应出错指令       0x0010CE04  ldr r3,[r3]，位于 pbuf_clen
上一层调用         tcp_free_acked_segments
```

TCP 发送段仍然引用 `0x00214AC0` 的 pbuf，但该位置已经成为 RGBA 像素数据；`0xFF4C4C4C` 是灰度 76、Alpha 255 的像素。默认 Data Abort 处理不会恢复主循环，因此整个串口和网络服务一同停止。

原固件使用同一份 80 MHz 位流：合成渐变图连续 600 帧成功，但直接 TCP 发送真实 `normal-23-4` 超声帧时，在打印第 50 帧进度后超时；随后 JTAG 再次确认停在同一个 Data Abort 处理函数。复现不经过浏览器。

## 并发错误与修复

当前 Xilinx GEM 驱动的发送完成中断调用：

```text
emacps_send_handler
  -> xemacps_process_sent_bds
    -> pbuf_free
      -> mem_free
```

主循环同时通过 `tcp_write(..., TCP_WRITE_FLAG_COPY)` 分配发送缓冲，调用 `mem_malloc`。原 BSP 是 `NO_SYS=1`，mutex 操作为空；`LWIP_ALLOW_MEM_FREE_FROM_OTHER_CONTEXT` 未定义，采用默认 0，堆分配与中断释放不能安全交错。单独启用 `SYS_LIGHTWEIGHT_PROT` 不能替代堆管理所需的另一项配置。

`scripts/vitis/network_bsp.py` 现在固定并审核：

```c
#define SYS_LIGHTWEIGHT_PROT 1
#define LWIP_ALLOW_MEM_FREE_FROM_OTHER_CONTEXT 1
```

修补 BSP 的生成输入，重编真正的 lwIP 库，并检查 BSP、编译用和导出给应用的三个头文件。新 ELF 的 `mem_malloc` 反汇编已确认调用 `sys_arch_protect/sys_arch_unprotect`，不能只改应用头文件而复用旧库。

本地确定性回归使用安装的 lwIP `mem.c` 副本，只加入一个模拟中断的调度点：分配器选中空闲块 B 后，中断释放相邻块 A。原配置会将 A/B 合并，造成后续两笔有效分配重叠；保护配置会推迟中断，两个有效分配保持分离。原算法代码没有被替换。

升频会改变吞吐与中断交错，可能使该竞争更容易触发；此次证据并不说明所有 CDC 都存在错误。修复后的对照保持原位流和 80 MHz 主频，只更新 PS/BSP。

## 上板对照

新 PS：`build/out/2026-10-25_232534_476f4da-dirty_huaZ6y/MID_plt.elf`。
同一 PL：`build/out/2026-10-25_172703_0116eee-dirty_nqkRRI/system_wrapper.bit`。

输入为 `normal-23-4` 文件夹前 50 张真实 BIN 循环，最多 8 帧在途。每张回传检查 CRC、长度、帧 ID、模式和 RGBA Alpha。

| 配置 | 完整回传帧数 | 总耗时 | 吞吐 | 结果 |
| --- | ---: | ---: | ---: | --- |
| HDMI 开 | 2000 | 33.56 秒 | 59.6 FPS | 全部完成，无卡死 |
| HDMI 关 | 5000 | 62.58 秒 | 79.9 FPS | 全部完成，无卡死 |

日志：`build/tests/freeze_repro/fixed_hdmi_on.log`、`fixed_hdmi_off.log`。
额外完成在途容量为 1、4、8 的三次独立重连测试，每次 20 帧；切换至伪彩模式和恢复灰度模式均通过。测试结束已恢复 HDMI 开、灰度模式，测试 TCP 连接全部关闭。
这些测试验证传输稳定性，不验证医学分割质量。

## 复测

本地堆竞争回归：

```bash
python scripts/tests/run_lwip_heap_checks.py
python -m unittest discover -s scripts/tests -p test_network_bsp.py
```

板卡和 GUI 均无其他流任务时，在仓库根目录执行真实帧测试（保持当前 PL 系统模式为图像处理模式）：

```bash
python scripts/tests/measure_stream_network.py --frames 2000 --capacities 8 --mode 0 \
  --folder E:/cardiarc_extract/cardiacUDC_gui_ready/sequences/label_all_frame/normal-23-4 \
  --send-chunk 3072 --send-pause .0001 --out build/tests/stream_freeze_recheck
```

以后重建 PS 仍使用：

```bash
./scripts/build.sh app -n MID_plt -p fpga_26 -f && bash ./scripts/flash_current.sh init
```

该修复不需要重新综合 PL。
