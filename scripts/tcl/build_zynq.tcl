# =============================================================================
#  build_zynq.tcl —— Zynq 全流程：建工程(+BD) -> 综合 -> 实现 -> 位流 -> 导出 xsa
# =============================================================================
#  由 scripts/build.sh zynq 调用，不直接使用。
#  参数: <工程名> <工程目录> [-axi] [并行数]
# =============================================================================

set name [lindex $argv 0]
set pdir [lindex $argv 1]
set jobs 4
set axi  ""

foreach a [lrange $argv 2 end] {
    if {$a eq "-axi"} { set axi "-axi" } elseif {$a ne ""} { set jobs $a }
}

if {$name eq "" || $pdir eq ""} {
    puts "!!!ARGS!!! build_zynq.tcl 需要: <工程名> <工程目录> [-axi] [并行数]"
    exit 1
}

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set xpr        [file join $pdir $name "${name}.xpr"]

puts "============================================================"
puts " \[build_zynq\] $name"
puts "   工程目录 : $pdir"
puts "   AXI 外设 : [expr {$axi eq "-axi" ? "是" : "否"}]"
puts "   并行数   : $jobs"
puts "============================================================"

# --------------------------- 1. 打开或新建工程 ------------------------------
if {[file exists $xpr]} {
    puts "\[build_zynq\] 打开已有工程（增量构建）"
    open_project $xpr
} else {
    puts "\[build_zynq\] 新建工程"
    set argv [list $name $pdir]
    if {$axi ne ""} { lappend argv $axi }
    source [file join $script_dir create_zynq_project.tcl]
}

# --------------------------- 2. 确认 BD 与顶层 ------------------------------
set bd [get_files -quiet *.bd]
if {$bd eq ""} {
    puts "!!!NOBD!!! 工程里没有 Block Design"
    exit 1
}
set bdname [file rootname [file tail [lindex $bd 0]]]
puts "\[build_zynq\] Block Design: $bdname"

if {[get_property top [current_fileset]] eq ""} {
    set wrapper [glob -nocomplain -directory [file join $pdir $name "${name}.gen" sources_1 bd $bdname hdl] *_wrapper.v]
    if {[llength $wrapper] > 0} {
        add_files -norecurse [lindex $wrapper 0]
        set_property top [file rootname [file tail [lindex $wrapper 0]]] [current_fileset]
    }
}
update_compile_order -fileset sources_1
puts "\[build_zynq\] 顶层: [get_property top [current_fileset]]"

# --------------------------- 3. 综合 / 实现 / 位流 --------------------------
puts "\[build_zynq\] 开始综合 ..."
reset_run -quiet synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "!!!SYNTH_FAILED!!!"
    exit 1
}

puts "\[build_zynq\] 开始实现 ..."
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "!!!IMPL_FAILED!!!"
    exit 1
}
puts "\[build_zynq\] 位流完成"

# --------------------------- 4. 导出硬件平台 .xsa ---------------------------
puts "\[build_zynq\] 导出 .xsa ..."
set xsa [file join $pdir $name "${name}.xsa"]
if {[catch {
    write_hw_platform -fixed -include_bit -force -file $xsa
} e]} {
    puts "\[build_zynq\] write_hw_platform 失败，改用 HDF 回退: $e"
    write_sysdef -hwdef [get_files -quiet *.hdf] -bitfile [lindex [glob -nocomplain -directory [get_property DIRECTORY [get_runs impl_1]] *.bit] 0] -file $xsa
}

if {[file exists $xsa]} {
    puts "XSA=$xsa"
} else {
    puts "!!!NOXSA!!! .xsa 生成失败"
}

set bit [glob -nocomplain -directory [get_property DIRECTORY [get_runs impl_1]] *.bit]
puts "BITSTREAM=$bit"
puts "PROJECT=$xpr"
close_project
puts "BUILD_ZYNQ_OK"
