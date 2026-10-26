# 阶段交付说明

工程位置：`E:\pld\cardiac_fpga_ip`（按要求所有交付物均在 E 盘）。

## 已完成

- 256×256 输入尺寸不变；输入/输出顶层采用用户给出的单像素 valid/ready/eof 流接口，并增加 `clk`、`rst`。
- 模型：U-Net 风格紧凑学生网络，8/16/32/64 通道，122,357 个参数；checkpoint 约 521 KB。INT8 权重和 Q20/Q12 参数供 FPGA HLS IP 使用。
- 学生模型验证集 float mean Dice 0.385914；INT8 mean Dice 0.385718；教师模型 mean Dice 0.457698。
- HLS IP 已导出到 `ip_repo\cardiac_unet_axis.zip`；Vivado Block Design 检查通过，针对 `xc7z015clg485-2` 的 `synth_1` 成功。
- Vivado 综合级系统资源：21,435 LUT / 46,200；22,437 FF / 92,400；58 BRAM Tile / 95；155 DSP / 160。
- `clk` 已加 50 ns（20 MHz）约束；综合时序 WNS +35.145 ns，0 setup failing endpoints。

## 解释和限制

- 这是 Vivado 综合级设计结果，尚未执行 place-and-route；当前 WNS 不能当成最终布局布线时序或硬件板卡验证。
- 约 3.88 秒/帧是按 HLS 固定网络各层的循环结构计算出的分析估算，非 FPGA 实测。HLS 报告中约 206 秒是动态参数产生的保守上界，也不是实测帧延迟。
- HLS IP 的权重、量化参数和约 11.94 MiB 工作区通过 AXI Master 访问 Zynq DDR。因此需要软件侧初始化 DDR、写入权重和参数，并正确启动 HLS 控制寄存器；不能把该 IP 当成无需 PS/DDR 配置即可独立工作的纯 PL 模块。
- 当前工程尚未生成可烧录 `.bit`，也未做板上验证。要完成此阶段，仍需实际开发板载板型号/引脚约束，以及确定数据由 PS、DMA 或外部视频流送入 AXI-Stream。
- `LA/RA/LV/RV_mask` 在每个输出 beat 表示对应像素是否属于该类；`LA/RA/LV/RV_ctr` 表示四邻域轮廓点。`out_data` 给出 0–4 类别编号。

## 主要文件

- `fpga_results.png`、`FPGA_RESULTS.html`：可视化结果。
- `INTERFACE_MAP.md`：接口、帧格式、DDR 连接与验证边界。
- `model_fpga_student.pth`、`model_fpga_student_best.pth`：学生模型 checkpoint。
- `weights_fpga_q8.bin`、`quant_params_fpga_q20_q12.bin`：HLS 使用的量化参数文件。
- `hls_src\unet_infer_axis.cpp`：AXI-Stream HLS 推理核心。
- `ip_repo\cardiac_unet_axis.zip`：打包后的 HLS IP。
- `vivado_axis_project\cardiac_unet_axis.xpr`：Vivado 工程。
- `vivado_axis_project\system_utilization.rpt`、`system_timing.rpt`：综合资源和约束时序报告。
