set proj_dir [file normalize [file join [file dirname [info script]] vivado_axis_project]]
open_project [file join $proj_dir cardiac_unet_axis.xpr]
add_files -fileset constrs_1 [file join $proj_dir external_clock.xdc]
set_property used_in_synthesis true [get_files external_clock.xdc]
set_property used_in_implementation true [get_files external_clock.xdc]
open_run synth_1
report_timing_summary -file [file join $proj_dir system_timing.rpt]
close_project
