# Idempotent migration for both a fresh BD and existing projects. No synthesis.
proc return_connect {source target} {
    set src [get_bd_pins $source];set dst [get_bd_pins $target]
    set old [get_bd_nets -quiet -of_objects $dst]
    if {[llength $old]==0} {connect_bd_net $src $dst} elseif {$old ne [get_bd_nets -quiet -of_objects $src]} {
        error "Unexpected existing connection at $target; expected $source"
    }
}
proc return_intf {source target} {
    set src [get_bd_intf_pins $source];set dst [get_bd_intf_pins $target]
    set old [get_bd_intf_nets -quiet -of_objects $dst]
    if {[llength $old]==0} {connect_bd_intf_net $src $dst} elseif {$old ne [get_bd_intf_nets -quiet -of_objects $src]} {
        error "Unexpected existing AXI connection at $target; expected $source"
    }
}
proc return_dma_config {} {
    return [list CONFIG.c_include_sg {0} CONFIG.c_include_mm2s {0} \
        CONFIG.c_include_s2mm {1} CONFIG.c_sg_length_width {23} \
        CONFIG.c_s_axis_s2mm_tdata_width {32} CONFIG.c_m_axi_s2mm_data_width {64} \
        CONFIG.c_include_s2mm_dre {0} CONFIG.c_addr_width {32} \
        CONFIG.c_sg_include_stscntrl_strm {0}]
}
proc ensure_return_dma {} {
    if {[get_bd_cells -quiet top1_0] eq "" || [get_bd_cells -quiet axi_ic_hp] eq ""} {
        error "S2MM requires top1_0 and the HP0 path; build with -H"
    }
    set dma axi_dma_return
    if {[get_bd_cells -quiet u_ila_hdmi] ne ""} {
        set_property CONFIG.C_PROBE0_WIDTH {128} [get_bd_cells u_ila_hdmi]
    }
    if {[get_bd_cells -quiet $dma] eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 $dma
    }
    set_property -dict [return_dma_config] [get_bd_cells $dma]
    # Locate/reuse this DMA's control port; otherwise append one GP0 master port.
    set control [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $dma/S_AXI_LITE]]
    if {[llength $control]==0} {
        set index [get_property CONFIG.NUM_MI [get_bd_cells axi_interconnect_0]]
        set_property CONFIG.NUM_MI [expr {$index+1}] [get_bd_cells axi_interconnect_0]
        set port [format "M%02d" $index]
        return_intf axi_interconnect_0/${port}_AXI $dma/S_AXI_LITE
        return_connect clk_wiz_0/clk_out1 axi_interconnect_0/${port}_ACLK
        return_connect rst_ps7_50M/peripheral_aresetn axi_interconnect_0/${port}_ARESETN
    }
    if {[get_property CONFIG.NUM_SI [get_bd_cells axi_ic_hp]] < 2} {
        set_property CONFIG.NUM_SI {2} [get_bd_cells axi_ic_hp]
    }
    return_intf $dma/M_AXI_S2MM axi_ic_hp/S01_AXI
    return_intf top1_0/M_AXIS $dma/S_AXIS_S2MM
    foreach pin {s_axi_lite_aclk m_axi_s2mm_aclk} {return_connect clk_wiz_0/clk_out1 $dma/$pin}
    return_connect rst_ps7_50M/peripheral_aresetn $dma/axi_resetn
    return_connect clk_wiz_0/clk_out1 axi_ic_hp/S01_ACLK
    return_connect rst_ps7_50M/peripheral_aresetn axi_ic_hp/S01_ARESETN
    # Explicit PS addresses: never rely on auto-allocation choosing the old base.
    foreach {cell base} {axi_vdma_0 0x43000000 top1_0 0x44000000 axi_dma_return 0x45000000} {
        set segment [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces processing_system7_0/Data] -filter "NAME =~ *${cell}*"]
        if {[llength $segment]==0} {
            set target [get_bd_addr_segs -of_objects [get_bd_intf_pins $cell/[expr {$cell eq "top1_0"?"S_AXI":"S_AXI_LITE"}]]]
            assign_bd_address -offset $base -range 64K -target_address_space [get_bd_addr_spaces processing_system7_0/Data] $target
        } else {set_property offset $base $segment}
    }
    assign_bd_address
    puts "S2MM_RETURN_OK control=0x45000000 stream=32 memory=64 length_bits=23 HP0=S01"
}
