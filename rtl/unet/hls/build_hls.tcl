# Unit HLS conversion only; no full-project build or board access.
if {[info exists ::env(FPGA_26_9_ROOT)] && $::env(FPGA_26_9_ROOT) ne ""} {
    set root [string map [list "\\" "/"] $::env(FPGA_26_9_ROOT)]
    set here [file join $root rtl unet hls]
} else {
    set here [file dirname [file normalize [info script]]]
    set root [file normalize [file join $here .. .. ..]]
}
cd $root
set out [file join $root build unet hls]
puts "UNET_HLS_ROOT=$root"
open_project -reset $out
set_top unet_ddr_core
add_files [file join $here unet_ddr_core.cpp] -cflags "-std=c++14 -I$here"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 4.0 -name default
config_interface -m_axi_addr64=false
config_rtl -reset all -reset_level high
config_compile -unsafe_math_optimizations=false
csynth_design
set target [file join $root rtl unet generated]
file mkdir $target
foreach path [glob -directory [file join $out solution syn verilog] *] {
    if {[file isfile $path]} {file copy -force $path $target}
}
# Ignore the Xilinx launcher's Python library environment.
exec python -I [file join $root rtl unet tools freshness.py] --record unet
puts "UNET_HLS_OK RTL=$target"
exit
