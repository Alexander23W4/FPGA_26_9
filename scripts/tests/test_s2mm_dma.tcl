# Actual AXI DMA behavioral simulation; no synthesis or board access.
set repo [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $repo scripts tcl s2mm_return.tcl]
set out [file join $repo build tests s2mm_dma]
create_project -force s2mm_check $out -part xc7z015clg485-2
create_ip -name axi_dma -vendor xilinx.com -library ip -version 7.1 -module_name return_dma
set_property -dict [return_dma_config] [get_ips return_dma]
generate_target simulation [get_ips return_dma]
if {[lsearch -exact $argv -generate-only] < 0} {
    add_files -fileset sim_1 [file join $repo sim tb tb_s2mm_dma.sv]
    set_property top tb_s2mm_dma [get_filesets sim_1]
    set_property xsim.simulate.runtime all [get_filesets sim_1]
    launch_simulation
    close_sim
}
close_project
