##

rm -f csrc/.lock

./scripts/build.sh app -n MID_plt


/e/Xilinx/Vitis/2023.2/bin/xsct.bat "$(cygpath -w scripts/tcl/flash_app.tcl)" \
  "$(cygpath -w csrc/MID_plt/build/MID_plt.elf)" \
  "$(cygpath -w csrc/fpga_26/hw/sdt/ps7_init.tcl)" init

/e/Xilinx/Vitis/2023.2/bin/xsct.bat "$(cygpath -w scripts/tcl/flash_app.tcl)" \
  "$(cygpath -w csrc/MID_plt/build/MID_plt.elf)" \
  "$(cygpath -w csrc/fpga_26/hw/sdt/ps7_init.tcl)" noinit


想干什么	命令
加图到 eMMC	    powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_add.ps1)" -File D:/test_img/iceberg.bin
看 eMMC 里有啥	powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_list.ps1)"
清空 eMMC	      powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_clear.ps1)"

跑test: 
               powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/run_test.ps1)" -Test pl_ctrl_test

笔记本开接收端:
powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/net_recv.ps1)" -TimeoutSec 180

eMMC 实数据 -> DDR -> VDMA 送流   	powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_to_ddr.ps1)" -Index 0


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


PC
 ↓
Ethernet
 ↓
ARM/Linux
 ↓
DDR
 ↓
AXI VDMA MM2S
 ↓
AXI-Stream
 ↓
PL 图像算法
 ↓
AXI-Stream
 ↓
AXI VDMA S2MM
 ↓
DDR
 ↓
ARM
 ↓
Ethernet
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