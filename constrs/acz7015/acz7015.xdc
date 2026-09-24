# =============================================================================
#  ACZ7015 引脚约束 —— 整理版
# -----------------------------------------------------------------------------
#  器件      : xc7z015clg485-2
#  来源      : 小梅哥官方例程 XDC（ch01/ch10/ch11/ch19/ch31 等）
#              + 09_硬件图纸 核心板 250804 / 底板 RevA
#              + 04_引脚信息\acz7015.xdc（原版，已去重整理）
#
#  ⚠ 使用说明
#    本文件是「板级引脚模板」，端口名沿用官方例程的命名。
#    你的顶层模块端口名必须与这里一致，否则 get_ports 找不到对象。
#    两种做法：
#      a) 顶层端口直接叫这些名字（最省事）
#      b) 只复制你用到的那几段，把端口名改成你自己的
#    不需要的外设请整段注释掉 —— 未约束的端口会报错。
#
#  ⚠ 关键板级事实（详见 _others/_env/硬件核对表.md）
#    · 系统时钟 50 MHz 输入在 L5（官方所有例程一致）
#    · PL 侧有两路千兆网？否 —— 只有 1 路 PL_ENET1；PS 侧另有 1 路
#    · 板上有两个 HDMI：
#         HDMI_1 (J6)  由 SIL9022A 驱动，FPGA 侧是并行 RGB
#         HDMI_2 (J7)  由 FPGA 直接输出原生 TMDS  ← 见第 2 节
#    · Micro SD 与 eMMC 共用 PS 侧 SD0(MIO40-45)，不可同时使用
# =============================================================================


# =============================================================================
# 0. 全局设置
# =============================================================================
# 未使用的引脚不做上拉（避免干扰板上外设）
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]

# 未约束端口不报错（调试期可选；正式工程建议关掉以保证约束完整）
# set_property SEVERITY {Warning} [get_drc_checks UCIO-1]


# =============================================================================
# 1. 时钟
# =============================================================================

# ---- 系统时钟：板上 50 MHz 有源晶振，接 FPGA L5 ----------------------------
# 官方所有例程（led_flash / key_led / pwm_gen / tft800x480_ctrl）均用 L5
create_clock -period 20.000 -name sys_clk [get_ports clk50M]
set_property PACKAGE_PIN L5 [get_ports clk50M]
set_property IOSTANDARD LVCMOS33 [get_ports clk50M]

# 若你的顶层端口叫 clk / clk_in50M，把上面三行的 clk50M 换成对应名字即可

# ---- 摄像头像素时钟（OV5640 PCLK，输入）-----------------------------------
# 周期 13.888 ns ≈ 72 MHz（OV5640 常用 PCLK 上限）
create_clock -period 13.888 -name Cam_PCLK [get_ports Cam_PCLK]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets Cam_PCLK_IBUF]


# =============================================================================
# 2. HDMI_2 (J7) —— FPGA 原生 TMDS 输出
# -----------------------------------------------------------------------------
#  板上 HDMI_2 由 FPGA 直接驱动 TMDS，链路：
#      FPGA 引脚 --49.9Ω 端接--> AZ1045 ESD --> HDMI 连接器 J7
#  需要 7 系列 OSERDESE2 做 10:1 串行化（5:1 DDR × 2），
#  配合 OBUFDS 输出差分对。IOSTANDARD 必须是 TMDS_33。
#
#  ⚠ 只约束差分对的 P 端，N 端由 Vivado 自动配对。
#  ⚠ 这 4 对引脚在 bank 34，属于 VCCIO_BANK1(3.3V) 域。
# =============================================================================
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p[0]}]
set_property IOSTANDARD TMDS_33 [get_ports tmds_clk_p]
set_property PACKAGE_PIN K7 [get_ports {tmds_data_p[2]}]
set_property PACKAGE_PIN M8 [get_ports {tmds_data_p[1]}]
set_property PACKAGE_PIN N6 [get_ports {tmds_data_p[0]}]
set_property PACKAGE_PIN T2 [get_ports tmds_clk_p]

# 原始 XDC 里同一组引脚还有一组别名（tmds_data_p_0 / tmds_clk_0_clk_p），
# 是不同例程留下的重复定义，此处已统一为 tmds_data_p / tmds_clk_p。
# 若你的顶层用旧名字，请改成：
#   set_property PACKAGE_PIN K7 [get_ports {tmds_data_p_0[2]}]
#   set_property PACKAGE_PIN M8 [get_ports {tmds_data_p_0[1]}]
#   set_property PACKAGE_PIN N6 [get_ports {tmds_data_p_0[0]}]
#   set_property PACKAGE_PIN T2 [get_ports tmds_clk_p_0]


# =============================================================================
# 3. 系统控制（LED / 按键 / 复位 / 蜂鸣器）
#    来源：官方 ch01 / ch10 / ch11 / ch19 例程
# =============================================================================

# ---- 复位按键 -------------------------------------------------------------
set_property PACKAGE_PIN R4 [get_ports reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_n]

# ---- 单个 LED（ch01 led_flash）-------------------------------------------
set_property PACKAGE_PIN P7 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]

# ---- 8 位 LED（ch11 key_led）---------------------------------------------
set_property PACKAGE_PIN AB14 [get_ports {led[0]}]
set_property PACKAGE_PIN AA14 [get_ports {led[1]}]
set_property PACKAGE_PIN AA15 [get_ports {led[2]}]
set_property PACKAGE_PIN AA12 [get_ports {led[3]}]
set_property PACKAGE_PIN R17  [get_ports {led[4]}]
set_property PACKAGE_PIN T17  [get_ports {led[5]}]
set_property PACKAGE_PIN U19  [get_ports {led[6]}]
set_property PACKAGE_PIN V19  [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]

# ---- 4 位按键（ch11 key_led）---------------------------------------------
set_property PACKAGE_PIN AB12 [get_ports {key_in0}]
set_property PACKAGE_PIN V11  [get_ports {key_in1}]
set_property PACKAGE_PIN W11  [get_ports {key_in2}]
set_property PACKAGE_PIN AA11 [get_ports {key_in3}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in0}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in1}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in2}]
set_property IOSTANDARD LVCMOS33 [get_ports {key_in3}]

# ---- 蜂鸣器（ch19 pwm_gen）-----------------------------------------------
set_property PACKAGE_PIN R2 [get_ports beep]
set_property IOSTANDARD LVCMOS33 [get_ports beep]


# =============================================================================
# 4. TFT LCD（5 寸 800x480 RGB 屏）—— 来源：ch31 tft800x480_ctrl
#    ⚠ 与 HDMI_1 的 RGB 总线共用，二选一
# =============================================================================
set_property PACKAGE_PIN J2 [get_ports {TFT_rgb[0]}]
set_property PACKAGE_PIN J1 [get_ports {TFT_rgb[1]}]
set_property PACKAGE_PIN L2 [get_ports {TFT_rgb[2]}]
set_property PACKAGE_PIN L1 [get_ports {TFT_rgb[3]}]
set_property PACKAGE_PIN M2 [get_ports {TFT_rgb[4]}]
set_property PACKAGE_PIN M3 [get_ports {TFT_rgb[5]}]
set_property PACKAGE_PIN J7 [get_ports {TFT_rgb[6]}]
set_property PACKAGE_PIN J6 [get_ports {TFT_rgb[7]}]
set_property PACKAGE_PIN R8 [get_ports {TFT_rgb[8]}]
set_property PACKAGE_PIN L4 [get_ports {TFT_rgb[9]}]
set_property PACKAGE_PIN H8 [get_ports {TFT_rgb[10]}]
set_property PACKAGE_PIN K4 [get_ports {TFT_rgb[11]}]
set_property PACKAGE_PIN K3 [get_ports {TFT_rgb[12]}]
set_property PACKAGE_PIN J5 [get_ports {TFT_rgb[13]}]
set_property PACKAGE_PIN K5 [get_ports {TFT_rgb[14]}]
set_property PACKAGE_PIN M4 [get_ports {TFT_rgb[15]}]
set_property PACKAGE_PIN M1 [get_ports TFT_clk]
set_property PACKAGE_PIN P6 [get_ports TFT_de]
set_property PACKAGE_PIN N1 [get_ports TFT_hs]
set_property PACKAGE_PIN P1 [get_ports TFT_vs]
set_property PACKAGE_PIN P5 [get_ports TFT_pwm]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[14]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[13]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[12]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[11]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[10]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {TFT_rgb[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports TFT_clk]
set_property IOSTANDARD LVCMOS33 [get_ports TFT_de]
set_property IOSTANDARD LVCMOS33 [get_ports TFT_hs]
set_property IOSTANDARD LVCMOS33 [get_ports TFT_vs]
set_property IOSTANDARD LVCMOS33 [get_ports TFT_pwm]


# =============================================================================
# 5. OV5640 摄像头（DVP 并口）
#    来源：原版 acz7015.xdc
# =============================================================================
set_property PACKAGE_PIN B4 [get_ports {Cam_Data[0]}]
set_property PACKAGE_PIN E7 [get_ports {Cam_Data[1]}]
set_property PACKAGE_PIN C6 [get_ports {Cam_Data[2]}]
set_property PACKAGE_PIN C5 [get_ports {Cam_Data[3]}]
set_property PACKAGE_PIN H4 [get_ports {Cam_Data[4]}]
set_property PACKAGE_PIN G4 [get_ports {Cam_Data[5]}]
set_property PACKAGE_PIN H3 [get_ports {Cam_Data[6]}]
set_property PACKAGE_PIN F4 [get_ports {Cam_Data[7]}]
set_property PACKAGE_PIN B3 [get_ports Cam_PCLK]
set_property PACKAGE_PIN E2 [get_ports Cam_Href]
set_property PACKAGE_PIN D2 [get_ports Cam_Vsync]
set_property PACKAGE_PIN F7 [get_ports XCLK]
set_property PACKAGE_PIN C3 [get_ports cam_scl_io]
set_property PACKAGE_PIN D3 [get_ports cam_sda_io]
set_property PULLUP true [get_ports cam_scl_io]
set_property PULLUP true [get_ports cam_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {Cam_Data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports Cam_Href]
set_property IOSTANDARD LVCMOS33 [get_ports Cam_PCLK]
set_property IOSTANDARD LVCMOS33 [get_ports Cam_Vsync]
set_property IOSTANDARD LVCMOS33 [get_ports XCLK]
set_property IOSTANDARD LVCMOS33 [get_ports cam_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports cam_sda_io]


# =============================================================================
# 6. 音频编解码器 WM8960（I2S）
# =============================================================================
set_property PACKAGE_PIN N3 [get_ports MCLK]
set_property PACKAGE_PIN P3 [get_ports BCLK]
set_property PACKAGE_PIN M6 [get_ports DACLRC]
set_property PACKAGE_PIN P2 [get_ports DACDAT]
set_property PACKAGE_PIN L6 [get_ports ADCLRC]
set_property PACKAGE_PIN N4 [get_ports ADCDAT]
set_property IOSTANDARD LVCMOS33 [get_ports MCLK]
set_property IOSTANDARD LVCMOS33 [get_ports ADCDAT]
set_property IOSTANDARD LVCMOS33 [get_ports ADCLRC]
set_property IOSTANDARD LVCMOS33 [get_ports BCLK]
set_property IOSTANDARD LVCMOS33 [get_ports DACDAT]
set_property IOSTANDARD LVCMOS33 [get_ports DACLRC]


# =============================================================================
# 7. PL 侧千兆以太网（RTL8211F-CG，RGMII）
#    ⚠ 这是 PL 网口；PS 侧另有一个网口走 PS_ENET0(MIO16-27)，不需要 XDC
# =============================================================================
set_property PACKAGE_PIN Y12 [get_ports {RGMII_0_rd[3]}]
set_property PACKAGE_PIN Y13 [get_ports {RGMII_0_rd[2]}]
set_property PACKAGE_PIN W12 [get_ports {RGMII_0_rd[1]}]
set_property PACKAGE_PIN W13 [get_ports {RGMII_0_rd[0]}]
set_property PACKAGE_PIN U13 [get_ports {RGMII_0_td[3]}]
set_property PACKAGE_PIN U14 [get_ports {RGMII_0_td[2]}]
set_property PACKAGE_PIN T16 [get_ports {RGMII_0_td[1]}]
set_property PACKAGE_PIN U16 [get_ports {RGMII_0_td[0]}]
set_property PACKAGE_PIN U18 [get_ports RGMII_0_txc]
set_property PACKAGE_PIN Y14 [get_ports RGMII_0_rxc]
set_property PACKAGE_PIN Y15 [get_ports RGMII_0_rx_ctl]
set_property PACKAGE_PIN U17 [get_ports RGMII_0_tx_ctl]
set_property PACKAGE_PIN U11 [get_ports MDIO_PHY_0_mdc]
set_property PACKAGE_PIN U12 [get_ports MDIO_PHY_0_mdio_io]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_rd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_rd[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_rd[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_rd[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_td[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_td[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_td[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {RGMII_0_td[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports RGMII_0_rx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports RGMII_0_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports RGMII_0_tx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports RGMII_0_txc]
set_property IOSTANDARD LVCMOS33 [get_ports MDIO_PHY_0_mdc]
set_property IOSTANDARD LVCMOS33 [get_ports MDIO_PHY_0_mdio_io]

# RGMII 接收时钟由 PHY 提供，需要作为时钟约束
# create_clock -period 8.000 -name rgmii_rxc [get_ports RGMII_0_rxc]
# set_input_delay -clock rgmii_rxc -max 1.5 [get_ports {RGMII_0_rd[*] RGMII_0_rx_ctl}]
# set_input_delay -clock rgmii_rxc -min 0.5 [get_ports {RGMII_0_rd[*] RGMII_0_rx_ctl}]


# =============================================================================
# 8. I2C（PL 侧，用于 HDMI-1/SIL9022A、TFT 触摸、摄像头等）
# =============================================================================
set_property PACKAGE_PIN J3 [get_ports IIC1_scl_io]
set_property PACKAGE_PIN K2 [get_ports IIC1_sda_io]
set_property PULLUP true [get_ports IIC1_scl_io]
set_property PULLUP true [get_ports IIC1_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports IIC1_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports IIC1_sda_io]


# =============================================================================
# 9. GPIO 扩展口
#    原版 XDC 把 40 引脚扩展口命名为 GPIO_0_0_tri_io[0..4] 和
#    GPIO0_0_tri_io[0..35] / GPIO1_0_tri_io[0..35]（来自 AXI GPIO 块设计的端口名）
#    含义：扩展排针的每一位。按需取用。
#    ⚠ 注意 led[7:0]/key_in[3:0] 也在 GPIO1 扩展口上（见第 3 节）
# =============================================================================

# ---- GPIO_0 扩展（5 位，原版命名为 tri_io[0..4]）-------------------------
set_property PACKAGE_PIN P7 [get_ports {GPIO_0_0_tri_io[0]}]
set_property PACKAGE_PIN R4 [get_ports {GPIO_0_0_tri_io[1]}]
set_property PACKAGE_PIN U2 [get_ports {GPIO_0_0_tri_io[2]}]
set_property PACKAGE_PIN U1 [get_ports {GPIO_0_0_tri_io[3]}]
set_property PACKAGE_PIN R7 [get_ports {GPIO_0_0_tri_io[4]}]
set_property PULLUP true [get_ports {GPIO_0_0_tri_io[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_0_0_tri_io[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_0_0_tri_io[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_0_0_tri_io[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_0_0_tri_io[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {GPIO_0_0_tri_io[4]}]

# ---- GPIO0 扩展口 36 位（bank 34/35）-------------------------------------
# 完整引脚表见 config/acz7015_pinmap.csv，此处列出以保持完整性
set_property PACKAGE_PIN B7  [get_ports {GPIO0_0_tri_io[0]}]
set_property PACKAGE_PIN B6  [get_ports {GPIO0_0_tri_io[1]}]
set_property PACKAGE_PIN D5  [get_ports {GPIO0_0_tri_io[2]}]
set_property PACKAGE_PIN C4  [get_ports {GPIO0_0_tri_io[3]}]
set_property PACKAGE_PIN G8  [get_ports {GPIO0_0_tri_io[4]}]
set_property PACKAGE_PIN G7  [get_ports {GPIO0_0_tri_io[5]}]
set_property PACKAGE_PIN C8  [get_ports {GPIO0_0_tri_io[6]}]
set_property PACKAGE_PIN B8  [get_ports {GPIO0_0_tri_io[7]}]
set_property PACKAGE_PIN H5  [get_ports {GPIO0_0_tri_io[8]}]
set_property PACKAGE_PIN H6  [get_ports {GPIO0_0_tri_io[9]}]
set_property PACKAGE_PIN G6  [get_ports {GPIO0_0_tri_io[10]}]
set_property PACKAGE_PIN F6  [get_ports {GPIO0_0_tri_io[11]}]
set_property PACKAGE_PIN H1  [get_ports {GPIO0_0_tri_io[12]}]
set_property PACKAGE_PIN G1  [get_ports {GPIO0_0_tri_io[13]}]
set_property PACKAGE_PIN G3  [get_ports {GPIO0_0_tri_io[14]}]
set_property PACKAGE_PIN G2  [get_ports {GPIO0_0_tri_io[15]}]
set_property PACKAGE_PIN F2  [get_ports {GPIO0_0_tri_io[16]}]
set_property PACKAGE_PIN F1  [get_ports {GPIO0_0_tri_io[17]}]
set_property PACKAGE_PIN E4  [get_ports {GPIO0_0_tri_io[18]}]
set_property PACKAGE_PIN E3  [get_ports {GPIO0_0_tri_io[19]}]
set_property PACKAGE_PIN D1  [get_ports {GPIO0_0_tri_io[20]}]
set_property PACKAGE_PIN C1  [get_ports {GPIO0_0_tri_io[21]}]
set_property PACKAGE_PIN F5  [get_ports {GPIO0_0_tri_io[22]}]
set_property PACKAGE_PIN E5  [get_ports {GPIO0_0_tri_io[23]}]
set_property PACKAGE_PIN B2  [get_ports {GPIO0_0_tri_io[24]}]
set_property PACKAGE_PIN B1  [get_ports {GPIO0_0_tri_io[25]}]
set_property PACKAGE_PIN D7  [get_ports {GPIO0_0_tri_io[26]}]
set_property PACKAGE_PIN D6  [get_ports {GPIO0_0_tri_io[27]}]
set_property PACKAGE_PIN A2  [get_ports {GPIO0_0_tri_io[28]}]
set_property PACKAGE_PIN A1  [get_ports {GPIO0_0_tri_io[29]}]
set_property PACKAGE_PIN E8  [get_ports {GPIO0_0_tri_io[30]}]
set_property PACKAGE_PIN D8  [get_ports {GPIO0_0_tri_io[31]}]
set_property PACKAGE_PIN A5  [get_ports {GPIO0_0_tri_io[32]}]
set_property PACKAGE_PIN A4  [get_ports {GPIO0_0_tri_io[33]}]
set_property PACKAGE_PIN A7  [get_ports {GPIO0_0_tri_io[34]}]
set_property PACKAGE_PIN A6  [get_ports {GPIO0_0_tri_io[35]}]

# ---- GPIO1 扩展口 36 位（bank 13）----------------------------------------
set_property PACKAGE_PIN AB21 [get_ports {GPIO1_0_tri_io[0]}]
set_property PACKAGE_PIN AB22 [get_ports {GPIO1_0_tri_io[1]}]
set_property PACKAGE_PIN AA19 [get_ports {GPIO1_0_tri_io[2]}]
set_property PACKAGE_PIN AA20 [get_ports {GPIO1_0_tri_io[3]}]
set_property PACKAGE_PIN AB18 [get_ports {GPIO1_0_tri_io[4]}]
set_property PACKAGE_PIN AB19 [get_ports {GPIO1_0_tri_io[5]}]
set_property PACKAGE_PIN Y18  [get_ports {GPIO1_0_tri_io[6]}]
set_property PACKAGE_PIN Y19  [get_ports {GPIO1_0_tri_io[7]}]
set_property PACKAGE_PIN AB16 [get_ports {GPIO1_0_tri_io[8]}]
set_property PACKAGE_PIN AB17 [get_ports {GPIO1_0_tri_io[9]}]
set_property PACKAGE_PIN AA16 [get_ports {GPIO1_0_tri_io[10]}]
set_property PACKAGE_PIN AA17 [get_ports {GPIO1_0_tri_io[11]}]
set_property PACKAGE_PIN AB13 [get_ports {GPIO1_0_tri_io[12]}]
set_property PACKAGE_PIN AB14 [get_ports {GPIO1_0_tri_io[13]}]
set_property PACKAGE_PIN AA14 [get_ports {GPIO1_0_tri_io[14]}]
set_property PACKAGE_PIN AA15 [get_ports {GPIO1_0_tri_io[15]}]
set_property PACKAGE_PIN AA12 [get_ports {GPIO1_0_tri_io[16]}]
set_property PACKAGE_PIN AB12 [get_ports {GPIO1_0_tri_io[17]}]
set_property PACKAGE_PIN V11  [get_ports {GPIO1_0_tri_io[18]}]
set_property PACKAGE_PIN W11  [get_ports {GPIO1_0_tri_io[19]}]
set_property PACKAGE_PIN AA11 [get_ports {GPIO1_0_tri_io[20]}]
set_property PACKAGE_PIN AB11 [get_ports {GPIO1_0_tri_io[21]}]
set_property PACKAGE_PIN R17  [get_ports {GPIO1_0_tri_io[22]}]
set_property PACKAGE_PIN T17  [get_ports {GPIO1_0_tri_io[23]}]
set_property PACKAGE_PIN U19  [get_ports {GPIO1_0_tri_io[24]}]
set_property PACKAGE_PIN V19  [get_ports {GPIO1_0_tri_io[25]}]
set_property PACKAGE_PIN V18  [get_ports {GPIO1_0_tri_io[26]}]
set_property PACKAGE_PIN W18  [get_ports {GPIO1_0_tri_io[27]}]
set_property PACKAGE_PIN W17  [get_ports {GPIO1_0_tri_io[28]}]
set_property PACKAGE_PIN Y17  [get_ports {GPIO1_0_tri_io[29]}]
set_property PACKAGE_PIN V16  [get_ports {GPIO1_0_tri_io[30]}]
set_property PACKAGE_PIN W16  [get_ports {GPIO1_0_tri_io[31]}]
set_property PACKAGE_PIN V15  [get_ports {GPIO1_0_tri_io[32]}]
set_property PACKAGE_PIN W15  [get_ports {GPIO1_0_tri_io[33]}]
set_property PACKAGE_PIN V13  [get_ports {GPIO1_0_tri_io[34]}]
set_property PACKAGE_PIN V14  [get_ports {GPIO1_0_tri_io[35]}]

# 扩展口统一 IO 标准（按需替换成你的端口名）
# 完整 IOSTANDARD 列表见原版 acz7015.xdc 第 163-315 行
