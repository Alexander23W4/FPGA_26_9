# U-Net only: processing/HDMI clocks and their counters remain unchanged.
proc unet_clock_connect {source target} {
    set src [get_bd_pins $source];set dst [get_bd_pins $target]
    set expected [get_bd_nets -quiet -of_objects $src]
    set old [get_bd_nets -quiet -of_objects $dst]
    if {$old eq $expected && $old ne ""} {return}
    if {$old ne ""} {disconnect_bd_net $old $dst}
    connect_bd_net $src $dst
}
proc ensure_unet_clock {} {
    set mhz 160.0
    if {[info exists ::env(UNET_CLK_MHZ)]} {set mhz $::env(UNET_CLK_MHZ)}
    if {![string is double -strict $mhz] || $mhz < 25 || $mhz > 250} {
        error "UNET_CLK_MHZ must be 25..250; implementation must pass timing"
    }
    if {[get_bd_cells -quiet clk_wiz_unet] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_unet
    }
    set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {126.000} \
        CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $mhz] [get_bd_cells clk_wiz_unet]
    unet_clock_connect clk_wiz_0/clk_out2 clk_wiz_unet/clk_in1
    unet_clock_connect clk_wiz_unet/clk_out1 top1_0/unet_clk
    set wizard [get_bd_cells clk_wiz_unet]
    set actual [expr {126.0*[get_property CONFIG.MMCM_CLKFBOUT_MULT_F $wizard]/
        [get_property CONFIG.MMCM_DIVCLK_DIVIDE $wizard]/[get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $wizard]}]
    if {abs($actual-$mhz)>0.001} {error "U-Net MMCM requested ${mhz}MHz, got ${actual}MHz"}
    if {[get_bd_cells -quiet unet_clocks_locked] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 unet_clocks_locked
        set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] [get_bd_cells unet_clocks_locked]
    }
    unet_clock_connect clocks_locked/Res unet_clocks_locked/Op1
    unet_clock_connect clk_wiz_unet/locked unet_clocks_locked/Op2
    unet_clock_connect unet_clocks_locked/Res rst_ps7_50M/dcm_locked
    if {[get_bd_cells -quiet rst_unet] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_unet
        set_property CONFIG.C_EXT_RESET_HIGH {1} [get_bd_cells rst_unet]
    }
    if {[get_bd_cells -quiet unet_zero] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 unet_zero
        set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells unet_zero]
    }
    unet_clock_connect clk_wiz_unet/clk_out1 rst_unet/slowest_sync_clk
    unet_clock_connect clk_wiz_unet/locked rst_unet/dcm_locked
    unet_clock_connect rst_ps7_50M/peripheral_reset rst_unet/ext_reset_in
    unet_clock_connect rst_unet/peripheral_reset top1_0/unet_rst
    foreach pin {aux_reset_in mb_debug_sys_rst} {unet_clock_connect unet_zero/dout rst_unet/$pin}
    set xdc [file normalize [file join $::unet_root constrs unet_clock_cdc.xdc]]
    if {[llength [get_files -quiet $xdc]]==0} {add_files -fileset constrs_1 -norecurse $xdc}
    set_property PROCESSING_ORDER LATE [get_files $xdc]
    puts "UNET_CLOCK_OK requested=${mhz}MHz actual=${actual}MHz processing/DDR/HDMI clocks preserved"
}
proc ensure_unet_axi_clock {source port name read_only} {
    if {[get_bd_cells -quiet $name] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 $name
    }
    set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.ADDR_WIDTH {32} \
        CONFIG.DATA_WIDTH {32} CONFIG.ID_WIDTH {1} CONFIG.ACLK_ASYNC {1} \
        CONFIG.SYNCHRONIZATION_STAGES {3}] [get_bd_cells $name]
    # Remove only the two known ends and our converter when migrating a direct
    # connection. S00/MM2S, S01/S2MM and registration/S04 are untouched.
    foreach path [list top1_0/$source axi_ic_hp/${port}_AXI $name/S_AXI $name/M_AXI] {
        set pin [get_bd_intf_pins $path]
        set net [get_bd_intf_nets -quiet -of_objects $pin]
        if {$net ne ""} {disconnect_bd_intf_net $net $pin}
    }
    connect_bd_intf_net [get_bd_intf_pins top1_0/$source] [get_bd_intf_pins $name/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins $name/M_AXI] [get_bd_intf_pins axi_ic_hp/${port}_AXI]
    unet_clock_connect clk_wiz_unet/clk_out1 $name/s_axi_aclk
    unet_clock_connect rst_unet/peripheral_aresetn $name/s_axi_aresetn
    unet_clock_connect clk_wiz_proc/clk_out1 $name/m_axi_aclk
    unet_clock_connect rst_ps7_50M/peripheral_aresetn $name/m_axi_aresetn
    return_connect clk_wiz_0/clk_out1 axi_ic_hp/${port}_ACLK
    return_connect rst_ps7_50M/peripheral_aresetn axi_ic_hp/${port}_ARESETN
}
