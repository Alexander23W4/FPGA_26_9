if {[info exists ::env(FPGA_26_9_ROOT)] && $::env(FPGA_26_9_ROOT) ne ""} {
    set root [string map [list "\\" "/"] $::env(FPGA_26_9_ROOT)]
    set here [file join $root rtl inter_fr ddr]
} else {
    set here [file dirname [file normalize [info script]]]
    set root [file normalize [file join $here .. .. ..]]
}
cd $root
open_project -reset [file join $root build unet registration_hls]
set_top registration_ddr_core
add_files [file join $here registration_ddr.cpp] -cflags "-std=c++14"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 12.5
config_interface -m_axi_addr64=false
csynth_design
set target [file join $here generated]
file mkdir $target
foreach path [glob -directory [file join $root build unet registration_hls solution syn verilog] *] {
    if {[file isfile $path]} {file copy -force $path $target}
}
# Ignore the Xilinx launcher's Python library environment.
exec python -I [file join $root rtl unet tools freshness.py] --record registration
puts "REGISTRATION_DDR_HLS_OK"
exit
