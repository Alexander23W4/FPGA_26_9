# =============================================================================
#  ACZ7015 PS7 Preset  —  Zynq-7000 processing_system7 一键配置
#  ★: 整块 PS 的完整配置： DDR3 内存控制器（含 PCB 走线延迟）、时钟树、Bank 电压、外设使能与参数
# ps7_preset 配置 PS 侧的控制器参数， 这些参数决定了外部芯片会被怎么驱动, 描述了控制器的feature, 每个外设控制器给外设怎么发信号 + 时钟树描述 + ...
#
# Vivado 根据 ps7_preset.tcl 把“硬件是什么”确定下来，生成 XSA；Vitis 再根据 XSA 生成类似你 AM 那一层的 BSP。
# 
#  ★★: Vivado 要读这个配置，才能给我的这个板子生成一个类似的 AM，把整个编译链的框架搭起来
# ACZ7015 原理图  +  PS MIO 资源表
#               │
#               │  你整理
#               ▼
#       ps7_preset.tcl                   
#               │
#               │  Vivado 读
#               ▼
#         PS7 硬件配置
#               │
#     ┌─────────┼──────────┐
#     ▼         ▼          ▼
#  ps7_init.c  .hwh      .bit
#  (11752行)   (地址表)   (PL)
#     │         │
#     │         └──────────────┐
#     │                        ▼
#     │                  System_wrapper.xsa
#     │                        │
#     │                        │  Vitis 读
#     │                        ▼
#     │                   BSP 生成器
#     │                ┌───────┴────────┐
#     │                ▼                ▼
#     │      【生成】xparameters.h   【拷贝】xuartps.c
#     │         (地址/时钟/ID)        (AMD 写好的驱动)
#     │                └───────┬────────┘
#     │                        ▼
#     │                  编译 → libxil.a
#     │                        │
#     ▼                        ▼
#   FSBL                  你的 hello_app.elf
# （上电配 PS）              （链接 libxil.a） 
# =============================================================================
#  目标器件 : xc7z015clg485-2
#  数据来源 : 小梅哥 ACZ7015_Linux_Base_Prj 的 system.bd（原厂实测可用配置）
#             + 09_硬件图纸 核心板 250804 / 底板 RevA
#             + 04_引脚信息\ACZ7015开发板PS MIO管脚资源表.xlsx
#
#  用法一（推荐，在 Block Design 里）：
#     source <本文件>
#     apply_acz7015_ps7_preset                      ;# 作用于名为 processing_system7_0 的单元
#     apply_acz7015_ps7_preset -cell my_ps7         ;# 指定单元名
#
#  用法二（只取参数字典，自行处理）：
#     source <本文件>
#     set d [acz7015_ps7_preset_dict]
#     set_property -dict $d [get_bd_cells processing_system7_0]
#
#  可选开关：
#     -no_usb0     不使能 USB0（复现原厂 Linux 基线配置）
#     -no_i2c0     不使能 I2C0（复现原厂 Linux 基线配置）
#     -no_qspi     不使能 QSPI
#     -no_enet     不使能 ENET0
#     -no_sd0      不使能 SD0
#     -fclk0 <MHz> 覆盖 FCLK0 频率（默认 50）
#     -apu   <MHz> 覆盖 APU 频率（默认 666.666666）
#
#  ── 与"原厂 Linux 基线配置"的两处差异（本预设默认更完整）─────────────────
#   1) USB0  (ULPI, MIO28-39)  原厂 Linux 基线里是关闭的，本预设默认开启
#      因为底板上确实有 USB3320 ULPI PHY（Sheet 11_USB）
#   2) I2C0  (MIO50-51)        原厂 Linux 基线里当作 GPIO，本预设默认开启
#      因为 MIO50/51 经 PCA9306 接到了 PS_I2C0（MIO 管脚资源表）
#    若要完全复现原厂基线，加 -no_usb0 -no_i2c0
# =============================================================================

namespace eval acz7015 {

    # -- 板级常量（来自原理图，勿随意改动）--------------------------------
    variable BANK0_VOLTAGE "LVCMOS 3.3V"   ;# MIO[7]=0  → Bank0( MIO0-15 ) = 3.3V
    variable BANK1_VOLTAGE "LVCMOS 1.8V"   ;# MIO[8]=1  → Bank1( MIO16-53) = 1.8V

    # ---------------------------------------------------------------------
    # 返回 PS7 参数字典
    # ---------------------------------------------------------------------
    proc ps7_preset_dict {args} {

        # ---- 默认开关 ----
        set opt(usb0)  1
        set opt(i2c0)  1
        set opt(qspi)  1
        set opt(enet)  1
        set opt(sd0)   1
        set opt(fclk0) 50
        set opt(apu)   666.666666

        # ---- 解析参数 ----
        for {set i 0} {$i < [llength $args]} {incr i} {
            set a [lindex $args $i]
            switch -- $a {
                -no_usb0 { set opt(usb0) 0 }
                -no_i2c0 { set opt(i2c0) 0 }
                -no_qspi { set opt(qspi) 0 }
                -no_enet { set opt(enet) 0 }
                -no_sd0  { set opt(sd0)  0 }
                -fclk0   { incr i; set opt(fclk0) [lindex $args $i] }
                -apu     { incr i; set opt(apu)   [lindex $args $i] }
                default  { error "acz7015::ps7_preset_dict: unknown option '$a'" }
            }
        }

        variable BANK0_VOLTAGE
        variable BANK1_VOLTAGE

        set p [list]

        # =================================================================
        # 1) 时钟体系
        #    33.333 MHz 晶振 → ARM PLL 1333.333 / DDR PLL 1066.667
        #    APU 666.667 MHz，FCLK0 50 MHz 送 PL
        # =================================================================
        lappend p CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ     33.333333
        lappend p CONFIG.PCW_APU_PERIPHERAL_FREQMHZ         $opt(apu)
        lappend p CONFIG.PCW_APU_CLK_RATIO_ENABLE           {6:2:1}
        lappend p CONFIG.PCW_CPU_PERIPHERAL_DIVISOR0        2
        lappend p CONFIG.PCW_DDR_DDR_PLL_FREQMHZ            1066.667
        lappend p CONFIG.PCW_DDRPLL_CTRL_FBDIV              32
        lappend p CONFIG.PCW_DDR_PERIPHERAL_DIVISOR0        2
        lappend p CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ       $opt(fclk0)
        lappend p CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ       50
        lappend p CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ       50
        lappend p CONFIG.PCW_FPGA3_PERIPHERAL_FREQMHZ       50
        lappend p CONFIG.PCW_FPGA_FCLK0_ENABLE              1
        lappend p CONFIG.PCW_EN_CLK0_PORT                   1
        lappend p CONFIG.PCW_EN_CLK1_PORT                   0
        lappend p CONFIG.PCW_EN_CLK2_PORT                   0
        lappend p CONFIG.PCW_EN_CLK3_PORT                   0
        lappend p CONFIG.PCW_CLK0_FREQ                      [expr {int($opt(fclk0) * 1000000)}]

        # =================================================================
        # 2) MIO Bank 电压
        #    原理图核心板直接标注：MIO[7]=0 → Bank0=3.3V；MIO[8]=1 → Bank1=1.8V
        # =================================================================
        lappend p CONFIG.PCW_PRESET_BANK0_VOLTAGE $BANK0_VOLTAGE
        lappend p CONFIG.PCW_PRESET_BANK1_VOLTAGE $BANK1_VOLTAGE

        # 逐脚 IOTYPE（决定 Bank 电压，必须与上面一致）
        for {set i 0} {$i <= 15} {incr i} {
            lappend p CONFIG.PCW_MIO_${i}_IOTYPE $BANK0_VOLTAGE
        }
        for {set i 16} {$i <= 53} {incr i} {
            lappend p CONFIG.PCW_MIO_${i}_IOTYPE $BANK1_VOLTAGE
        }

        # =================================================================
        # 3) DDR3  —— 2 × 4Gb x16 DDR3L，32 位，1 GB，1.35V，1066 Mbps
        #    实物可能是 南亚 NT5CC256M16ER-EKI 或 镁光 MT41K256M16TW-107，
        #    但 MIG/PS7 器件库里没有南亚型号，故统一按镁光 RE-125 配置，
        #    两者组织完全一致（4Gb x16 / 8bank / 32K row / 1K col），可互换。
        #    注意：必须 MT41K（1.35V DDR3L），不能选 MT41J（1.5V）
        # =================================================================
        lappend p CONFIG.PCW_UIPARAM_DDR_ENABLE               1
        lappend p CONFIG.PCW_UIPARAM_DDR_PARTNO               {MT41K256M16 RE-125}
        lappend p CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE          {DDR 3}
        lappend p CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH            {32 Bit}
        lappend p CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH           {16 Bits}
        lappend p CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY      {4096 MBits}
        lappend p CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ             533.333333
        lappend p CONFIG.PCW_UIPARAM_DDR_SPEED_BIN            DDR3_1066F
        lappend p CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT       15
        lappend p CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT       10
        lappend p CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT      3
        lappend p CONFIG.PCW_UIPARAM_DDR_CL                    7
        lappend p CONFIG.PCW_UIPARAM_DDR_CWL                   6
        lappend p CONFIG.PCW_UIPARAM_DDR_BL                    8
        lappend p CONFIG.PCW_UIPARAM_DDR_T_RCD                 7
        lappend p CONFIG.PCW_UIPARAM_DDR_T_RP                  7
        lappend p CONFIG.PCW_UIPARAM_DDR_T_RC                  48.75
        lappend p CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN             35.0
        lappend p CONFIG.PCW_UIPARAM_DDR_T_FAW                 40.0
        lappend p CONFIG.PCW_UIPARAM_DDR_HIGH_TEMP             {Normal (0-85)}
        lappend p CONFIG.PCW_UIPARAM_DDR_ECC                   Disabled
        lappend p CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF     0
        lappend p CONFIG.PCW_UIPARAM_DDR_AL                    0
        lappend p CONFIG.PCW_UIPARAM_DDR_ADV_ENABLE            0
        lappend p CONFIG.PCW_UIPARAM_DDR_CLOCK_STOP_EN         0
        lappend p CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE        1
        lappend p CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE       1
        lappend p CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL     1
        lappend p CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0          0.25
        lappend p CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1          0.25
        lappend p CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2          0.25
        lappend p CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3          0.25
        lappend p CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0    0.0
        lappend p CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1    0.0
        lappend p CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2    0.0
        lappend p CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3    0.0
        # 1 GB 地址范围 0x0000_0000 - 0x3FFF_FFFF
        lappend p CONFIG.PCW_DDR_RAM_HIGHADDR                  0x3FFFFFFF

        # =================================================================
        # 4) QSPI Flash  —— W25Q128JVSIQ 16MB，MIO1-6，单 CS，x4
        # =================================================================
        if {$opt(qspi)} {
            lappend p CONFIG.PCW_QSPI_PERIPHERAL_ENABLE     1
            lappend p CONFIG.PCW_QSPI_QSPI_IO               {MIO 1 .. 6}
            lappend p CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE  1
            lappend p CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO      {MIO 1 .. 6}
            lappend p CONFIG.PCW_QSPI_GRP_SS1_ENABLE        0
            lappend p CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE      0
            lappend p CONFIG.PCW_SINGLE_QSPI_DATA_MODE      x4
            lappend p CONFIG.PCW_QSPI_PERIPHERAL_FREQMHZ    200
            lappend p CONFIG.PCW_EN_QSPI                    1
        }

        # =================================================================
        # 5) ENET0 千兆  —— RTL8211F-CG，RGMII on MIO16-27，MDIO on MIO52/53
        #    注意：原厂 MIO 表把这一路写成 PS_ENET1，但原理图网络名是
        #          PS_ENET0_*，且 MIO16-27 就是 ENET0 的固定 MIO 区间。
        #          以原理图为准 → 用 ENET0
        # =================================================================
        if {$opt(enet)} {
            lappend p CONFIG.PCW_ENET0_PERIPHERAL_ENABLE    1
            lappend p CONFIG.PCW_ENET0_ENET0_IO             {MIO 16 .. 27}
            lappend p CONFIG.PCW_ENET0_GRP_MDIO_ENABLE      1
            lappend p CONFIG.PCW_ENET0_GRP_MDIO_IO          {MIO 52 .. 53}
            lappend p CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ   {1000 Mbps}
            lappend p CONFIG.PCW_ENET_RESET_ENABLE          0
            lappend p CONFIG.PCW_EN_ENET0                   1
        }

        # =================================================================
        # 6) USB0  —— USB3320 ULPI PHY，MIO28-39
        # =================================================================
        if {$opt(usb0)} {
            lappend p CONFIG.PCW_USB0_PERIPHERAL_ENABLE     1
            lappend p CONFIG.PCW_USB0_USB0_IO               {MIO 28 .. 39}
            lappend p CONFIG.PCW_USB_RESET_ENABLE           0
            lappend p CONFIG.PCW_EN_USB0                    1
        }

        # =================================================================
        # 7) SD0 / eMMC  —— MIO40-45，4 位
        #    ⚠ 底板的 Micro SD 与核心板的 eMMC 共用 SD0（MIO40-45），
        #      硬件上无法同时使用，软件里二选一
        # =================================================================
        if {$opt(sd0)} {
            lappend p CONFIG.PCW_SD0_PERIPHERAL_ENABLE      1
            lappend p CONFIG.PCW_SD0_SD0_IO                 {MIO 40 .. 45}
            lappend p CONFIG.PCW_SD0_GRP_CD_ENABLE          0
            lappend p CONFIG.PCW_SD0_GRP_WP_ENABLE          0
            lappend p CONFIG.PCW_SD0_GRP_POW_ENABLE         0
            lappend p CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ    100
            lappend p CONFIG.PCW_SDIO_PERIPHERAL_VALID      1
            lappend p CONFIG.PCW_EN_SDIO0                   1
        }

        # =================================================================
        # 8) UART1  —— 接 CH9102F（USB 转串口），MIO48/49 @ 1.8V
        # =================================================================
        lappend p CONFIG.PCW_UART1_PERIPHERAL_ENABLE        1
        lappend p CONFIG.PCW_UART1_UART1_IO                 {MIO 48 .. 49}
        lappend p CONFIG.PCW_UART1_GRP_FULL_ENABLE          0
        lappend p CONFIG.PCW_UART_PERIPHERAL_FREQMHZ        100
        lappend p CONFIG.PCW_UART_PERIPHERAL_VALID          1
        lappend p CONFIG.PCW_EN_UART1                       1

        # =================================================================
        # 9) I2C0  —— MIO50/51 经 PCA9306 电平转换，接 RTC / EEPROM / HDMI
        # =================================================================
        if {$opt(i2c0)} {
            lappend p CONFIG.PCW_I2C0_PERIPHERAL_ENABLE     1
            lappend p CONFIG.PCW_I2C0_I2C0_IO               {MIO 50 .. 51}
            lappend p CONFIG.PCW_I2C_RESET_ENABLE           0
            lappend p CONFIG.PCW_EN_I2C0                    1
        }

        # =================================================================
        # 10) GPIO
        #     MIO GPIO 使能（PS_LED0=MIO7 / PS_KEY0=MIO47 / MIO8-15 扩展口）
        #     EMIO GPIO 引出 2 位到 PL（与原厂基线一致）
        # =================================================================
        lappend p CONFIG.PCW_GPIO_MIO_GPIO_ENABLE           1
        lappend p CONFIG.PCW_GPIO_MIO_GPIO_IO               MIO
        lappend p CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE          1
        lappend p CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH           2
        lappend p CONFIG.PCW_EN_GPIO                        1

        return $p
    }

    # ---------------------------------------------------------------------
    # 把预设应用到 Block Design 里的 PS7 单元
    # ---------------------------------------------------------------------
    proc apply_ps7_preset {args} {
        set cell "processing_system7_0"
        set rest [list]
        for {set i 0} {$i < [llength $args]} {incr i} {
            set a [lindex $args $i]
            if {$a eq "-cell"} { incr i; set cell [lindex $args $i] } else { lappend rest $a }
        }

        if {[catch {set bdcell [get_bd_cells -quiet $cell]}] || $bdcell eq ""} {
            error "acz7015: Block Design cell '$cell' not found. Open the BD and place a processing_system7 first."
        }

        set p [ps7_preset_dict {*}$rest]
        puts "\[ACZ7015\] Applying PS7 preset to $cell ([expr {[llength $p]/2}] parameters) ..."
        set_property -dict $p $bdcell
        puts "\[ACZ7015\] PS7 preset applied."
        return $bdcell
    }
}

# 顶层别名，方便直接调用
proc apply_acz7015_ps7_preset {args} { return [acz7015::apply_ps7_preset {*}$args] }
proc acz7015_ps7_preset_dict     {args} { return [acz7015::ps7_preset_dict {*}$args] }

puts "\[ACZ7015\] PS7 preset loaded. Available commands:"
puts "           apply_acz7015_ps7_preset ?-cell <name>? ?-no_usb0? ?-no_i2c0? ..."
