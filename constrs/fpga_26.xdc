# =============================================================================
# FPGA_26 工程专用约束（ACZ7015 / xc7z015clg485-2）
#
# 顶层 system_wrapper 仅引出 clk50M 与 HDMI_2 原生 TMDS 端口。
# 完整的板级引脚参考见 constrs/acz7015/acz7015.xdc；该参考文件不参与本工程。
# =============================================================================

set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]

# 板载 50 MHz 晶振，L5。
create_clock -period 20.000 -name sys_clk [get_ports clk50M]
set_property PACKAGE_PIN L5 [get_ports clk50M]
set_property IOSTANDARD LVCMOS33 [get_ports clk50M]

# HDMI_2 (J7)：FPGA 原生 TMDS 输出。P/N 两端均须声明 TMDS_33；
# 差分对的 N 端引脚由 Vivado 根据 P 端自动配对。
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_p[0]}]
set_property IOSTANDARD TMDS_33 [get_ports tmds_tx_p]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_n[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_n[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {tmds_data_n[0]}]
set_property IOSTANDARD TMDS_33 [get_ports tmds_tx_n]
set_property PACKAGE_PIN K7 [get_ports {tmds_data_p[2]}]
set_property PACKAGE_PIN M8 [get_ports {tmds_data_p[1]}]
set_property PACKAGE_PIN N6 [get_ports {tmds_data_p[0]}]
set_property PACKAGE_PIN T2 [get_ports tmds_tx_p]

# HDMI 串行移位寄存器每 5 个 126 MHz 周期才从 25.2 MHz 域重新取数。
set_multicycle_path -setup 5 -from [get_clocks clk_out1_system_clk_wiz_0_0_1] -to [get_clocks clk_out2_system_clk_wiz_0_0_1]
set_multicycle_path -hold  4 -from [get_clocks clk_out1_system_clk_wiz_0_0_1] -to [get_clocks clk_out2_system_clk_wiz_0_0_1]
