set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
open_project -reset [file join $root build unet emit_cosim]
set_top unet_emit_probe
add_files [file join $here emit_probe.cpp] -cflags "-std=c++14"
add_files -tb [file join $here emit_probe_tb.cpp] -cflags "-std=c++14"
open_solution -reset solution -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 12.5
config_interface -m_axi_addr64=false
csim_design
csynth_design
cosim_design -rtl verilog -tool xsim
puts "UNET_EMIT_COSIM_OK"
exit
