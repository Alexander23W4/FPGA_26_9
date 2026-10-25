# The complete-model design fits Z-7015 only without the old deep trace cores.
# Keep all functional RTL/data paths. Explicit FPGA_DEBUG_ILA=1 preserves the
# existing instrumentation for separate debug builds with a suitable budget.
proc configure_debug_budget {} {
    set enabled 0
    if {[info exists ::env(FPGA_DEBUG_ILA)]} {
        set flag $::env(FPGA_DEBUG_ILA)
        if {![string is boolean -strict $flag]} {
            error "FPGA_DEBUG_ILA must be a Tcl boolean, for example 0 or 1"
        }
        set enabled [expr {$flag ? 1 : 0}]
    }
    if {$enabled} {
        puts "DEBUG_BUDGET ILA=enabled explicitly; check device BRAM capacity"
        return
    }
    set removed {}
    foreach name {u_ila_hdmi u_ila_saxi u_ila_vdma_mm2s} {
        set cell [get_bd_cells -quiet $name]
        if {[llength $cell]} {
            set vlnv [get_property VLNV $cell]
            if {![string match "xilinx.com:ip:ila:*" $vlnv] &&
                ![string match "xilinx.com:ip:system_ila:*" $vlnv]} {
                error "Refusing to remove non-ILA cell $name ($vlnv)"
            }
            delete_bd_objs $cell
            lappend removed $name
        }
    }
    puts "DEBUG_BUDGET ILA=disabled removed=$removed; functional data paths preserved"
}
