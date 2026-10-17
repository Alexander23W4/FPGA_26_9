# Validate board XDC parsing and HDMI selectors against a real full-system DCP.
# Does not overwrite the checkpoint or open/edit the user's Vivado project.
set root [file normalize [file join [file dirname [info script]] ../..]]
open_checkpoint [file join $root build vivado fpga_26 fpga_26.runs impl_1 system_wrapper_routed.dcp]
read_xdc [file join $root constrs fpga_26.xdc]
close_design
open_checkpoint [file join $root build tests processing_clock routed_80MHz.dcp]
read_xdc [file join $root constrs processing_cdc.xdc]
report_cdc -from [get_clocks processing] -to [get_clocks pixel] -details -file [file join $root build tests processing_clock final_cdc_to_pixel.rpt]
report_cdc -from [get_clocks pixel] -to [get_clocks processing] -details -file [file join $root build tests processing_clock final_cdc_from_pixel.rpt]
puts "CLOCK_CONSTRAINTS_OK: board XDC, generated HDMI clocks, CDC XDC"
close_design
