if {[info exists ::env(FPGA_26_9_ROOT)]} {
    set root [string map [list "\\" "/"] $::env(FPGA_26_9_ROOT)]
} else {set root [file normalize [file join [file dirname [info script]] .. .. ..]]}
cd $root
set out [file join $root build unet small_hls]
open_project -reset $out
set_top small_unet_ddr_core
add_files [file join $root rtl unet small_hls small_unet.cpp] -cflags "-std=c++14 -I[file join $root rtl unet small_hls]"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 4.0 -name default
config_interface -m_axi_addr64=false
config_rtl -reset all -reset_level high
config_compile -pipeline_loops 0
csynth_design
set target [file join $root rtl unet small_generated]
file mkdir $target
foreach path [glob -directory [file join $out solution syn verilog] *] {
    if {[file isfile $path]} {file copy -force $path $target}
}
exec python -I [file join $root rtl unet tools freshness.py] --record unet
puts "SMALL_UNET_HLS_OK RTL=$target"
exit
