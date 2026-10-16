# Vivado batch: create/validate a scratch BD; never launches synthesis.
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set argv [list fpga_26 [file join $repo build tests network_bd] -hp]
source [file join $repo scripts tcl create_zynq_project.tcl]
validate_bd_design
set before [get_property CONFIG.NUM_MI [get_bd_cells axi_interconnect_0]]
ensure_return_dma
ensure_return_dma
validate_bd_design
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
puts "NETWORK_BD_OK: 32-bit S2MM, 64-bit HP0, 256KiB receive, stable addresses, idempotent migration"
close_project
