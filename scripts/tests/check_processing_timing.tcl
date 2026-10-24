# Standalone synthesis/placement timing experiment; never touches build/vivado
# or publishes a bitstream/XSA. A routed full-system build is still required.
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build tests processing_clock]
file mkdir $out
set mhz [expr {[llength $argv] ? [lindex $argv 0] : 80.0}]
create_project -in_memory -part xc7z015clg485-2
foreach file [glob $root/rtl/*.v $root/rtl/thresholder/*.v $root/rtl/inter_fr/*.v $root/rtl/heart_analysis/*.v] {read_verilog $file}
synth_design -top top1 -mode out_of_context -part xc7z015clg485-2 -generic CLK_HZ=[expr {int($mhz*1000000)}]
create_clock -name processing -period [expr {1000.0/$mhz}] [get_ports clk]
create_clock -name pixel -period [expr {1000.0/25.2}] [get_ports pclk]
create_clock -name serializer -period [expr {1000.0/126.0}] [get_ports pclk_x5]
set_false_path -from [get_ports rst]
set_multicycle_path -setup 5 -from [get_clocks pixel] -to [get_clocks serializer]
set_multicycle_path -hold -end 4 -from [get_clocks pixel] -to [get_clocks serializer]
source [file join $root constrs processing_cdc.xdc]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file $out/timing_${mhz}MHz.rpt
report_timing -from [get_clocks processing] -to [get_clocks processing] -max_paths 10 -file $out/processing_${mhz}MHz.rpt
report_cdc -from [get_clocks processing] -to [get_clocks pixel] -details -file $out/cdc_to_pixel_${mhz}MHz.rpt
report_cdc -from [get_clocks pixel] -to [get_clocks processing] -details -file $out/cdc_from_pixel_${mhz}MHz.rpt
report_utilization -file $out/utilization_${mhz}MHz.rpt
write_checkpoint -force $out/routed_${mhz}MHz.dcp
puts "PROCESSING_TIMING_EXPERIMENT_DONE $mhz MHz; requires routed full-system validation"
