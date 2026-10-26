set root [file normalize [file dirname [info script]]]
set proj_dir [file join $root vivado_axis_project]
set ip_dir [file join $root hls_project_axis solution1 impl ip]
create_project -force cardiac_unet_axis $proj_dir -part xc7z015clg485-2
set_property ip_repo_paths [list $ip_dir] [current_project]
update_ip_catalog -rebuild
if {[llength [get_ipdefs -all xilinx.com:hls:unet_infer:1.0]] == 0} { error "Streaming HLS IP not found" }
create_bd_design design_1
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_USE_S_AXI_HP1 {1} \
  CONFIG.PCW_USE_S_AXI_HP2 {1} \
  CONFIG.PCW_EN_CLK0_PORT {0} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {20} \
] $ps
set core [create_bd_cell -type ip -vlnv xilinx.com:hls:unet_infer:1.0 cardiac_unet_0]
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_20M]
set clk_port [create_bd_port -dir I -type clk -freq_hz 20000000 clk]
set rst_port [create_bd_port -dir I -type rst rst]
set_property CONFIG.POLARITY {ACTIVE_HIGH} $rst_port
set data_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc_data]
set ctrl_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc_ctrl]
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {3}] $data_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ctrl_smc
make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/DDR]
make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/FIXED_IO]
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_smc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M00_AXI] [get_bd_intf_pins cardiac_unet_0/s_axi_control]
connect_bd_intf_net [get_bd_intf_pins cardiac_unet_0/m_axi_gmem1] [get_bd_intf_pins axi_smc_data/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins cardiac_unet_0/m_axi_gmem2] [get_bd_intf_pins axi_smc_data/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins cardiac_unet_0/m_axi_gmem3] [get_bd_intf_pins axi_smc_data/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M01_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M02_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP2]
foreach pin {M_AXI_GP0_ACLK S_AXI_HP0_ACLK S_AXI_HP1_ACLK S_AXI_HP2_ACLK} {
  connect_bd_net [get_bd_ports clk] [get_bd_pins processing_system7_0/$pin]
}
connect_bd_net [get_bd_ports clk] [get_bd_pins rst_ps7_0_20M/slowest_sync_clk]
connect_bd_net [get_bd_ports clk] [get_bd_pins axi_smc_data/aclk]
connect_bd_net [get_bd_ports clk] [get_bd_pins axi_smc_ctrl/aclk]
connect_bd_net [get_bd_ports rst] [get_bd_pins rst_ps7_0_20M/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps7_0_20M/peripheral_aresetn] [get_bd_pins cardiac_unet_0/ap_rst_n]
connect_bd_net [get_bd_pins rst_ps7_0_20M/peripheral_aresetn] [get_bd_pins axi_smc_data/aresetn]
connect_bd_net [get_bd_pins rst_ps7_0_20M/peripheral_aresetn] [get_bd_pins axi_smc_ctrl/aresetn]
connect_bd_net [get_bd_ports clk] [get_bd_pins cardiac_unet_0/ap_clk]

set c_one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $c_one
set c_zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $c_zero
foreach pin {input_stream_TKEEP input_stream_TSTRB} {
  connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins cardiac_unet_0/$pin]
}
connect_bd_net [get_bd_pins const_zero/dout] [get_bd_pins cardiac_unet_0/input_stream_TUSER]
make_bd_pins_external -name in_data [get_bd_pins cardiac_unet_0/input_stream_TDATA]
make_bd_pins_external -name in_valid [get_bd_pins cardiac_unet_0/input_stream_TVALID]
make_bd_pins_external -name in_ready [get_bd_pins cardiac_unet_0/input_stream_TREADY]
make_bd_pins_external -name in_eof [get_bd_pins cardiac_unet_0/input_stream_TLAST]
make_bd_pins_external -name out_data [get_bd_pins cardiac_unet_0/output_stream_TDATA]
make_bd_pins_external -name out_valid [get_bd_pins cardiac_unet_0/output_stream_TVALID]
make_bd_pins_external -name out_ready [get_bd_pins cardiac_unet_0/output_stream_TREADY]
make_bd_pins_external -name out_eof [get_bd_pins cardiac_unet_0/output_stream_TLAST]
set flags {LA_mask RA_mask LV_mask RV_mask LA_ctr RA_ctr LV_ctr RV_ctr}
for {set bit 0} {$bit < 8} {incr bit} {
  set slice [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 slice_$bit]
  set_property -dict [list CONFIG.DIN_WIDTH {8} CONFIG.DIN_FROM $bit CONFIG.DIN_TO $bit] $slice
  connect_bd_net [get_bd_pins cardiac_unet_0/output_stream_TUSER] [get_bd_pins slice_$bit/Din]
  set flag [lindex $flags $bit]
  make_bd_pins_external -name $flag [get_bd_pins slice_$bit/Dout]
}
make_bd_pins_external -name interrupt [get_bd_pins cardiac_unet_0/interrupt]
assign_bd_address
validate_bd_design
save_bd_design
set bd_file [get_files [file join $proj_dir cardiac_unet_axis.srcs sources_1 bd design_1 design_1.bd]]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
update_compile_order -fileset sources_1
close_project


