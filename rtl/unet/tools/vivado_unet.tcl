# Source inside a Vivado project. IP sources under ip/ are never touched.
set ::unet_root [file normalize [file join [file dirname [info script]] .. .. ..]]
source [file join $::unet_root rtl unet tools unet_clock.tcl]
proc prepare_unet_operators {} {
    set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
    # Vivado exports its own PYTHONHOME/PYTHONPATH. Isolate the external
    # interpreter so it uses its matching standard library instead.
    puts [exec python -I [file join $::unet_root rtl unet tools freshness.py] --check]
    set dir [file join $::unet_root rtl unet small_generated]
    if {![file exists [file join $dir small_unet_ddr_core.v]]} {
        error "Missing small U-Net RTL: run rtl/unet/tools/build.sh first"
    }
    # Old FP32 sources remain recoverable, but must not synthesize their
    # floating-point operator IPs in the active integer-model project.
    foreach file [get_files -all -quiet -filter {NAME =~ */rtl/unet/generated/*}] {remove_files $file}
    foreach ip [get_ips -quiet unet_ddr_core_*_ip] {
        set file [get_property IP_FILE $ip]
        if {$file ne ""} {remove_files $file}
    }
    foreach script [lsort [glob -nocomplain -directory $dir *_ip.tcl]] {
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
    ensure_unet_clock
    ensure_unet_axi_clock M_AXI_UNET_WEIGHTS S02 unet_weights_clock 1
    ensure_unet_axi_clock M_AXI_UNET_FEATURES S03 unet_features_clock 0
    return_intf top1_0/M_AXI_REGISTRATION axi_ic_hp/S04_AXI
    return_connect clk_wiz_0/clk_out1 axi_ic_hp/S04_ACLK
    return_connect rst_ps7_50M/peripheral_aresetn axi_ic_hp/S04_ARESETN
    foreach source {M_AXI_UNET_WEIGHTS M_AXI_UNET_FEATURES M_AXI_REGISTRATION} {
        set space [get_bd_addr_spaces -of_objects [get_bd_intf_pins top1_0/$source]]
        if {[llength $space]!=1} {error "Cannot infer U-Net address space $source"}
        set ddr [get_bd_addr_segs -of_objects [get_bd_intf_pins processing_system7_0/S_AXI_HP0] -filter {NAME =~ *DDR*}]
        assign_bd_address -target_address_space $space $ddr
    }
    puts "UNET_DDR_OK weights=0x28000000 workspace=0x2c000000 registration=0x2e000000 HP0=S02/S03/S04 AXI width conversion=32-to-64"
}
