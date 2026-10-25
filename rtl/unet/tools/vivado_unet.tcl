# Source inside a Vivado project. IP sources under ip/ are never touched.
set ::unet_root [file normalize [file join [file dirname [info script]] .. .. ..]]
proc prepare_unet_operators {} {
    # Vivado exports its own PYTHONHOME/PYTHONPATH. Isolate the external
    # interpreter so it uses its matching standard library instead.
    puts [exec python -I [file join $::unet_root rtl unet tools freshness.py] --check]
    set dir [file join $::unet_root rtl unet generated]
    if {![file exists [file join $dir unet_ddr_core.v]]} {
        error "Missing complete U-Net RTL: run rtl/unet/hls/build_hls.tcl with Vitis HLS first"
    }
    foreach script [lsort [glob -directory $dir *_ip.tcl]] {
        set name [file rootname [file tail $script]]
        if {[llength [get_ips -quiet $name]]==0} {source $script}
    }
    foreach data [glob -nocomplain -directory $dir *.dat] {
        if {[llength [get_files -quiet $data]]==0} {add_files -norecurse $data}
    }
}
proc ensure_unet_ddr {} {
    if {[get_bd_cells -quiet top1_0] eq ""} {return}
    if {[get_bd_cells -quiet axi_ic_hp] eq ""} {error "U-Net requires the DDR HP path (-H)"}
    # S00 is MM2S; S01 is S2MM. Never reuse either port or the stream DDR ring.
    if {[get_property CONFIG.NUM_SI [get_bd_cells axi_ic_hp]]<5} {
        set_property CONFIG.NUM_SI 5 [get_bd_cells axi_ic_hp]
    }
    foreach {source port} {M_AXI_UNET_WEIGHTS S02 M_AXI_UNET_FEATURES S03 M_AXI_REGISTRATION S04} {
        return_intf top1_0/$source axi_ic_hp/${port}_AXI
        return_connect clk_wiz_0/clk_out1 axi_ic_hp/${port}_ACLK
        return_connect rst_ps7_50M/peripheral_aresetn axi_ic_hp/${port}_ARESETN
        set space [get_bd_addr_spaces -of_objects [get_bd_intf_pins top1_0/$source]]
        if {[llength $space]!=1} {error "Cannot infer U-Net address space $source"}
        set ddr [get_bd_addr_segs -of_objects [get_bd_intf_pins processing_system7_0/S_AXI_HP0] -filter {NAME =~ *DDR*}]
        assign_bd_address -target_address_space $space $ddr
    }
    puts "UNET_DDR_OK weights=0x28000000 workspace=0x2c000000 registration=0x2e000000 HP0=S02/S03/S04 AXI width conversion=32-to-64"
}
