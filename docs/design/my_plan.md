##
首先写一个最简单的收发

ps读.bin文件, 然后传给DDR

pl从ddr里面读取图像, 然后直接用HDMI输出给电脑


PS DDR
  ↑
PS7 S_AXI_HP0
  ↑
AXI SmartConnect
  ↑

AXI VDMA MM2S

  ↓ AXI4-Stream

AXI4-Stream FIFO
  ↓
256×256 图像位置控制
  ↓
RGB565 → RGB888
  ↓
640×480 视频时序合成
  ↓
TMDS Encoder
  ↓
OSERDESE2 10:1
  ↓
OBUFDS
  ↓
HDMI_2

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