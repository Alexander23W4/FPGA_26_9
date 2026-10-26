set root [string map [list "\\" "/"] $::env(FPGA_26_9_ROOT)]
cd $root
set kind $::env(SMALL_PROBE)
if {$kind ni {kernel emit}} {error "expected kernel or emit"}
open_project -reset [file join $root build unet small_${kind}_cosim]
set_top small_${kind}_probe
set includes "-std=c++14 -I[file join $root rtl unet small_hls]"
add_files [file join $root rtl unet tests small_${kind}_probe.cpp] -cflags $includes
add_files -tb [file join $root rtl unet tests small_${kind}_tb.cpp] -cflags $includes
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 5
config_interface -m_axi_addr64=false
config_compile -pipeline_loops 0
config_rtl -reset all -reset_level high
csim_design -O
csynth_design
cosim_design -rtl verilog
puts "SMALL_[string toupper $kind]_COSIM_OK"
exit
