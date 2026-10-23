# Vivado batch: create/validate a scratch BD; never launches synthesis.
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set argv [list fpga_26 [file join $repo build tests network_bd] -hp]
source [file join $repo scripts tcl create_zynq_project.tcl]
validate_bd_design
set before [get_property CONFIG.NUM_MI [get_bd_cells axi_interconnect_0]]
ensure_return_dma
ensure_return_dma
ensure_processing_clock
ensure_processing_clock
validate_bd_design
set proc_net [get_bd_nets -of_objects [get_bd_pins clk_wiz_proc/clk_out1]]
set proc_input_net [get_bd_nets -of_objects [get_bd_pins clk_wiz_proc/clk_in1]]
if {$proc_input_net ne [get_bd_nets -of_objects [get_bd_pins clk_wiz_0/clk_out2]]} {
    error "processing MMCM must use the buffered 126-MHz clock"
}
if {[get_property CONFIG.PRIM_SOURCE [get_bd_cells clk_wiz_proc]] ne "No_buffer"} {
    error "processing MMCM must not add a second input buffer"
}
foreach pin {top1_0/clk processing_system7_0/M_AXI_GP0_ACLK processing_system7_0/S_AXI_HP0_ACLK axi_dma_return/m_axi_s2mm_aclk axi_vdma_0/m_axis_mm2s_aclk rst_ps7_50M/slowest_sync_clk} {
    if {[get_bd_nets -of_objects [get_bd_pins $pin]] ne $proc_net} {error "wrong processing clock: $pin"}
}
if {[get_bd_nets -of_objects [get_bd_pins top1_0/pclk]] eq $proc_net} {error "pixel clock migrated with processing clock"}
if {[get_property CONFIG.CLK_HZ [get_bd_cells top1_0]] != 80000000} {error "wrong frequency register parameter"}
if {[get_property CONFIG.NUM_MI [get_bd_cells axi_interconnect_0]] != $before} {error "DMA migration is not idempotent"}
if {[get_property CONFIG.c_sg_length_width [get_bd_cells axi_dma_return]] < 19} {error "DMA length too narrow"}
if {[get_property CONFIG.c_s_axis_s2mm_tdata_width [get_bd_cells axi_dma_return]] != 32} {error "stream width"}
if {[get_property CONFIG.c_m_axi_s2mm_data_width [get_bd_cells axi_dma_return]] != 64} {error "memory width"}
foreach pin {axi_dma_return/M_AXI_S2MM processing_system7_0/S_AXI_HP0} {
    set width [get_property CONFIG.DATA_WIDTH [get_bd_intf_pins $pin]]
    if {$width != 64} {error "actual interface $pin width is $width, expected 64"}
    puts "NETWORK_WIDTH_OK $pin=$width"
}
# Interconnect's boundary pins have no CONFIG.DATA_WIDTH property. Check the
# connected endpoints instead; validate_bd_design also checks width conversion.
foreach {first second} {axi_dma_return/M_AXI_S2MM axi_ic_hp/S01_AXI axi_ic_hp/M00_AXI processing_system7_0/S_AXI_HP0} {
    if {[get_bd_intf_nets -of_objects [get_bd_intf_pins $first]] ne
        [get_bd_intf_nets -of_objects [get_bd_intf_pins $second]]} {error "wrong HP0 connection: $first -> $second"}
}
foreach {cell base} {axi_vdma_0 0x43000000 top1_0 0x44000000 axi_dma_return 0x45000000} {
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces processing_system7_0/Data] -filter "NAME =~ *${cell}*"]
    if {[llength $seg]!=1 || [expr {[get_property OFFSET $seg]}] != [expr {$base}]} {error "wrong address for $cell"}
}
puts "NETWORK_BD_OK: shared input buffer, 80-MHz processing clock, 32-bit S2MM, 64-bit HP0, stable addresses, idempotent migration"
close_project
