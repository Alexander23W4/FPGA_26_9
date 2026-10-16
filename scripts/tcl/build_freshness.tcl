# Refresh generated BD modules before launching synthesis. Keep this separate so
# preparation and the implemented-register checks can be tested without a build.
proc sync_repo_rtl {dir} {
    foreach path [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $path]} {
            sync_repo_rtl $path
        } elseif {[file extension $path] eq ".v"} {
            set path [file normalize $path]
            if {[llength [get_files -quiet $path]] == 0} {
                add_files -norecurse $path
                puts "RTL_SOURCE_ADDED $path"
            }
        }
    }
}

proc prepare_fresh_bd {bd} {
    update_compile_order -fileset sources_1
    config_ip_cache -disable_cache
    open_bd_design $bd
    set refs [get_ips -all -quiet -filter {IPDEF =~ xilinx.com:module_ref:*}]
    foreach ref $refs {
        puts "\[build_zynq\] Refreshing module reference: $ref"
        update_module_reference $ref
    }
    if {[llength [info commands ensure_return_dma]]} {ensure_return_dma}
    validate_bd_design
    save_bd_design
    reset_target all $bd
    generate_target all $bd -force
    create_ip_run $bd
    update_compile_order -fileset sources_1
    puts "BD_REFRESH_OK module_references=[llength $refs] cache=disabled"
}

proc verify_pl_registers {report_path} {
    set video [get_cells -quiet -hier -filter {
        NAME =~ */u_axi_slv/reg_video_mode_reg* && IS_SEQUENTIAL == 1}]
    set area [get_cells -quiet -hier -filter {
        NAME =~ */lesion_pixels_save_reg* && IS_SEQUENTIAL == 1}]
    set alpha [get_cells -quiet -hier -filter {
        NAME =~ */u_axi_slv/reg_mask_transparency_reg* && IS_SEQUENTIAL == 1}]
    set fp [open $report_path w]
    puts $fp "video_mode_register_bits=[llength $video]"
    puts $fp "area_saved_register_bits=[llength $area]"
    puts $fp "mask_transparency_register_bits=[llength $alpha]"
    puts $fp "video_cells=$video"
    puts $fp "area_cells=$area"
    close $fp
    if {[llength $video] == 0 || [llength $area] < 17 || [llength $alpha] < 7} {
        error "!!!STALE_PL!!! Implemented top1 is missing video_mode, saved area, or mask transparency. See $report_path"
    }
    puts "PL_REGISTERS_OK video_bits=[llength $video] area_bits=[llength $area] alpha_bits=[llength $alpha]"
}
