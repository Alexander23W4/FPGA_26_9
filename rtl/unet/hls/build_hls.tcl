# Unit HLS conversion only; no full-project build or board access.
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set out [file join $root build unet hls]
open_project -reset $out
set_top unet_ddr_core
add_files [file join $here unet_ddr_core.cpp] -cflags "-std=c++14 -I$here"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 12.5 -name default
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
