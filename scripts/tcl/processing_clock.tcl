# Called for new and existing BDs after the return DMA exists. The processing
# MMCM is cascaded from the existing 126-MHz serializer clock so both MMCMs do
# not place separate input buffers on the single clk50M package pin.
set ::processing_cdc_file [file normalize [file join [file dirname [info script]] .. .. constrs processing_cdc.xdc]]
proc ensure_processing_clock {} {
    set mhz 80.0
    if {[info exists ::env(PL_CLK_MHZ)]} {set mhz $::env(PL_CLK_MHZ)}
    if {![string is double -strict $mhz] || $mhz < 25 || $mhz > 250} {
        error "PL_CLK_MHZ must be 25..250 MHz; timing closure is required at every rate"
    }
    if {[get_bd_cells -quiet top1_0] eq ""} {return}
    if {[llength [get_files -quiet $::processing_cdc_file]] == 0} {
        add_files -fileset constrs_1 -norecurse $::processing_cdc_file
    }
    set_property PROCESSING_ORDER LATE [get_files $::processing_cdc_file]
    if {[get_bd_cells -quiet clk_wiz_proc] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_proc
    }
    set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {126.000} \
        CONFIG.USE_RESET {false} \
            CONFIG.USE_LOCKED {true}] [get_bd_cells clk_wiz_proc]
    set input_net [get_bd_nets -of_objects [get_bd_pins clk_wiz_proc/clk_in1]]
    set expected_input_net [get_bd_nets -of_objects [get_bd_pins clk_wiz_0/clk_out2]]
    if {$input_net ne $expected_input_net} {
        if {$input_net ne ""} {disconnect_bd_net $input_net [get_bd_pins clk_wiz_proc/clk_in1]}
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins clk_wiz_proc/clk_in1]
    }
    set_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $mhz [get_bd_cells clk_wiz_proc]
    set wizard [get_bd_cells clk_wiz_proc]
    set actual [expr {126.0 * [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $wizard] /
        [get_property CONFIG.MMCM_DIVCLK_DIVIDE $wizard] /
        [get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $wizard]}]
    if {abs($actual-$mhz) > 0.001} {
        error "Requested ${mhz}MHz cannot be generated exactly; MMCM selected ${actual}MHz"
    }
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
    puts "PROCESSING_CLOCK_OK requested=${mhz}MHz actual=${actual}MHz source=clk_wiz_0/clk_out2@126MHz pclk=25.2MHz"
}

# write_bitstream can finish despite timing violations. Never publish that build
# as the current hardware platform or allow an app to pair with it silently.
proc verify_implemented_timing {report_path} {
    report_timing_summary -report_unconstrained -file $report_path
    foreach kind {max min} {
        set path [get_timing_paths -quiet -delay_type $kind -max_paths 1]
        if {[llength $path] != 1} {error "!!!TIMING_UNKNOWN!!! No $kind timing path"}
        set slack [get_property SLACK $path]
        puts "IMPLEMENTED_TIMING $kind slack=${slack}ns"
        if {$slack < 0.0} {error "!!!TIMING_FAILED!!! $kind slack=${slack}ns; see $report_path"}
    }
}
