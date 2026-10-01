# HDMI 局部仿真

这两个测试平台覆盖当前显示通路中最容易出错的局部行为：

- `tb_double_buf`：两个帧缓冲 bank 的独立写入与 pclk 域一拍读取。
- `tb_hdmi_out`：HDMI 可视窗口、HSYNC / VSYNC、帧缓冲读地址递增、帧尾清零，以及读地址计数器的同步复位。

在 Git Bash 中分别运行：

```bash
./scripts/build.sh sim -n fpga26_local -b tb_double_buf
./scripts/build.sh sim -n fpga26_local -b tb_hdmi_out
```

日志出现对应的 `[PASS]` 和 `SIM_OK` 才算通过。
