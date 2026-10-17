# Called for new and existing BDs after the return DMA exists. Pixel clocks stay
# on the original MMCM; all AXI/processing loads migrate together to a new MMCM.
proc ensure_processing_clock {} {
    set mhz 100.0
    if {[info exists ::env(PL_CLK_MHZ)]} {set mhz $::env(PL_CLK_MHZ)}
    if {![string is double -strict $mhz] || $mhz < 25 || $mhz > 250} {
        error "PL_CLK_MHZ must be 25..250 MHz; timing closure is required at every rate"
    }
    if {[get_bd_cells -quiet top1_0] eq ""} {return}
    if {[get_bd_cells -quiet clk_wiz_proc] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_proc
        set_property -dict [list CONFIG.PRIM_IN_FREQ {50.000} CONFIG.USE_RESET {false} \
            CONFIG.USE_LOCKED {true}] [get_bd_cells clk_wiz_proc]
        connect_bd_net [get_bd_ports clk50M] [get_bd_pins clk_wiz_proc/clk_in1]
    }
    set_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $mhz [get_bd_cells clk_wiz_proc]
    set actual [get_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [get_bd_cells clk_wiz_proc]]
    set_property CONFIG.CLK_HZ [expr {int(round($actual*1000000))}] [get_bd_cells top1_0]
    set old [get_bd_nets -of_objects [get_bd_pins clk_wiz_0/clk_out1]]
    foreach pin [get_bd_pins -of_objects $old -filter {DIR == I}] {
        if {[string trimleft $pin /] eq "top1_0/pclk"} {continue}
        disconnect_bd_net $old $pin
        connect_bd_net [get_bd_pins clk_wiz_proc/clk_out1] $pin
    }
    # Both MMCMs must be locked before global reset releases. Per-domain RTL
    # synchronizers then release processing, pixel and serializer resets locally.
    if {[get_bd_cells -quiet clocks_locked] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 clocks_locked
        set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] [get_bd_cells clocks_locked]
        set dst [get_bd_pins rst_ps7_50M/dcm_locked]
        disconnect_bd_net [get_bd_nets -of_objects $dst] $dst
        connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins clocks_locked/Op1]
        connect_bd_net [get_bd_pins clk_wiz_proc/locked] [get_bd_pins clocks_locked/Op2]
        connect_bd_net [get_bd_pins clocks_locked/Res] $dst
    }
    puts "PROCESSING_CLOCK_OK requested=${mhz}MHz pclk=25.2MHz serializer=126MHz"
}
