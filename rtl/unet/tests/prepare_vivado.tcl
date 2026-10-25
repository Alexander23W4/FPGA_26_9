set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set project [file join $root build unet vivado unet_check.xpr]
if {[file exists $project]} {open_project $project} else {
    create_project unet_check [file join $root build unet vivado] -part xc7z015clg485-2
}
set_property target_language Verilog [current_project]
source [file join $root rtl unet tools vivado_unet.tcl]
prepare_unet_operators
proc add_rtl {dir} {
    foreach path [glob -directory $dir *] {
        if {[file isdirectory $path]} {add_rtl $path} elseif {[file extension $path] eq ".v"} {add_files -norecurse $path}
    }
}
add_rtl [file join $root rtl]
set_property top top1 [current_fileset]
set_property top top1 [current_fileset -simset]
update_compile_order -fileset sources_1
export_simulation -simulator xsim -directory [file join $root build unet xsim] -force
puts "UNET_VIVADO_PREPARED"
close_project
exit
