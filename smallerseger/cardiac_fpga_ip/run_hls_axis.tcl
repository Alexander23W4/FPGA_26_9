set root [file normalize [file dirname [info script]]]
set project_dir [file join $root hls_project_axis]
set export_dir [file join $root ip_repo cardiac_unet_axis]
open_project -reset $project_dir
set src_dir [file join $project_dir src]
file mkdir $src_dir
file copy -force [file join $root hls_src unet_infer_axis.cpp] [file join $src_dir unet_infer_axis.cpp]
file copy -force [file join $root hls_src model_layout_fpga5.h] [file join $src_dir model_layout_fpga5.h]
add_files [file join $src_dir unet_infer_axis.cpp] -cflags "-I$src_dir"
set_top unet_infer
open_solution -reset solution1 -flow_target vivado
set_part xc7z015clg485-2
create_clock -period 20.0 -name default
csynth_design
export_design -format ip_catalog -output $export_dir
exit





