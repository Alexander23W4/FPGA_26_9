set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
open_project -reset [file join $root build unet kernel_cosim]
set_top unet_kernel_probe
add_files [file join $here kernel_probe.cpp] -cflags "-std=c++14"
add_files -tb [file join $here kernel_probe_tb.cpp] -cflags "-std=c++14"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 4.0
config_compile -unsafe_math_optimizations=false
config_interface -m_axi_addr64=false
csim_design
csynth_design
cosim_design -rtl verilog -tool xsim
puts "UNET_KERNEL_COSIM_OK"
exit
