# Recreate the old shared-clock topology ONLY in the scratch test BD, then
# exercise the same migration used by the user's existing project.
set root [file normalize [file join [file dirname [info script]] ../..]]
open_project [file join $root build tests network_bd fpga_26 fpga_26.xpr]
open_bd_design [get_files *.bd]
source [file join $root scripts tcl processing_clock.tcl]
source [file join $root scripts tcl s2mm_return.tcl]
set oldnet [get_bd_nets -of_objects [get_bd_pins clk_wiz_0/clk_out1]]
set procnet [get_bd_nets -of_objects [get_bd_pins clk_wiz_proc/clk_out1]]
foreach pin [get_bd_pins -of_objects $procnet -filter {DIR == I}] {
    disconnect_bd_net $procnet $pin
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] $pin
}
set lockpin [get_bd_pins rst_ps7_50M/dcm_locked]
disconnect_bd_net [get_bd_nets -of_objects $lockpin] $lockpin
connect_bd_net [get_bd_pins clk_wiz_0/locked] $lockpin
delete_bd_objs [get_bd_cells clocks_locked] [get_bd_cells clk_wiz_proc]
ensure_return_dma
ensure_processing_clock
ensure_return_dma
ensure_processing_clock
validate_bd_design
set procnet [get_bd_nets -of_objects [get_bd_pins clk_wiz_proc/clk_out1]]
foreach pin {top1_0/clk processing_system7_0/M_AXI_GP0_ACLK processing_system7_0/S_AXI_HP0_ACLK axi_dma_return/m_axi_s2mm_aclk axi_vdma_0/m_axis_mm2s_aclk rst_ps7_50M/slowest_sync_clk u_ila_hdmi/clk} {
    if {[get_bd_nets -of_objects [get_bd_pins $pin]] ne $procnet} {error "unmigrated clock: $pin"}
}
if {[get_bd_nets -of_objects [get_bd_pins top1_0/pclk]] eq $procnet} {error "pixel clock migrated"}
if {[get_property PROCESSING_ORDER [get_files $::processing_cdc_file]] ne "LATE"} {error "CDC XDC not loaded late"}
save_bd_design
puts "PROCESSING_MIGRATION_OK: shared 25.2MHz -> separate 80MHz; CDC XDC registered late; idempotent"
close_project
