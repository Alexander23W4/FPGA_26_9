set root [string map [list "\\" "/"] $::env(FPGA_26_9_ROOT)]
cd $root
set project_name small_csim
if {[info exists ::env(SMALL_CSIM_TAG)]} {append project_name _$::env(SMALL_CSIM_TAG)}
open_project -reset [file join $root build unet $project_name]
set_top small_unet_ddr_core
add_files [file join $root rtl unet small_hls small_unet.cpp] -cflags "-std=c++14 -I[file join $root rtl unet small_hls]"
add_files -tb [file join $root rtl unet tests small_native_tb.cpp] -cflags "-std=c++14 -I[file join $root rtl unet small_hls]"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 5
csim_design -O -clean -argv "[file join $root build unet model weights.bin] [file join $root build unet small_check] 3"
puts "SMALL_CSIM_VERIFIED"
exit
