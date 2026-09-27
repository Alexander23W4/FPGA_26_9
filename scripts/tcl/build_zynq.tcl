# =============================================================================
#  build_zynq.tcl —— Zynq 全流程：建工程(+BD) -> 综合 -> 实现 -> 位流 -> 导出 xsa
# =============================================================================
#  由 scripts/build.sh zynq 调用，不直接使用。
#
#  参数: <工程名> <工程目录> [-axi] [-hp] [-fclk0 <MHz>] [并行数]
#
#  ★ 工程已存在时不会重建 BD。改了 BD 结构（比如新加 -hp）必须删掉
#    build/vivado/<工程名> 重跑，否则改动不会生效。
# =============================================================================

set name [lindex $argv 0]
set pdir [lindex $argv 1]
set jobs 4
set pass [list]

set _i 2
while {$_i < [llength $argv]} {
    set a [lindex $argv $_i]
    switch -- $a {
        -axi   { lappend pass -axi }
        -hp    { lappend pass -hp }
        -fclk0 { incr _i ; lappend pass -fclk0 [lindex $argv $_i] }
        default { if {[string is integer -strict $a]} { set jobs $a } }
    }
    incr _i
}

if {$name eq "" || $pdir eq ""} {
    puts "!!!ARGS!!! build_zynq.tcl requires: <name> <projdir> \[-axi\] \[-hp\] \[-fclk0 <MHz>\] \[jobs\]"
    exit 1
}

set script_dir [file normalize [file dirname [info script]]]
set xpr        [file join $pdir $name "${name}.xpr"]
set want_hp    [expr {[lsearch -exact $pass "-hp"] >= 0 ? 1 : 0}]

puts "============================================================"
puts " \[build_zynq\] $name"
puts "   Project dir : $pdir"
puts "   Pass-through: $pass"
puts "   PL->DDR HP  : [expr {$want_hp ? "yes" : "no"}]"
puts "   Jobs        : $jobs"
puts "============================================================"

# --------------------------- 1. 打开或新建工程 ------------------------------
if {[file exists $xpr]} {
    puts "\[build_zynq\] Opening existing project (incremental build)"
    open_project $xpr

    # 请求了 -hp 但工程里的 BD 是旧结构 -> 直接拦下来，别浪费时间综合
    if {$want_hp} {
        set bdfiles [get_files -quiet *.bd]
        if {[llength $bdfiles] > 0} {
            set fp [open [lindex $bdfiles 0] r]
            set bdtext [read $fp]
            close $fp
            if {[string first "S_AXI_HP0" $bdtext] < 0} {
                puts "!!!HP_MISSING!!! this project's Block Design has no S_AXI_HP0."
                puts "                 Delete build/vivado/$name (or use build.sh -R)"
                puts "                 and re-run to rebuild the BD with -hp."
                exit 1
            }
        }
    }
} else {
    puts "\[build_zynq\] Creating new project"
    set argv [concat [list $name $pdir] $pass]
    source [file join $script_dir create_zynq_project.tcl]
}

# --------------------------- 2. 确认 BD 与顶层 ------------------------------
set bd [get_files -quiet *.bd]
if {$bd eq ""} {
    puts "!!!NOBD!!! No Block Design found in the project"
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
puts "\[build_zynq\] Top module: [get_property top [current_fileset]]"

# --------------------------- 3. 综合 / 实现 / 位流 --------------------------
# ★★ 必须把所有 *_synth_1 都 reset，不能只 reset 顶层的 synth_1。
#    BD 里每个 module reference / 每个 IP 都有自己的 OOC 综合 run
#    （system_top1_0_0_synth_1、system_axi_vdma_0_0_synth_1 ...）。
#    只 reset synth_1 的话，RTL 改了 Vivado 会把旧网表直接拿去用。
#    现象是"综合实现位流全都跑了，但新加的端口/寄存器在 FPGA 里根本不存在"，
#    读它只会得到 default 值 —— 排查时会被这个骗得团团转。实测踩过。
puts "\[build_zynq\] Resetting all synthesis runs ..."
reset_run -quiet synth_1
set _ooc [get_runs -quiet *_synth_1]
foreach _r $_ooc {
    reset_run -quiet $_r
}
puts "\[build_zynq\] OOC synth runs reset: [llength $_ooc]"

puts "\[build_zynq\] Starting synthesis ..."
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "!!!SYNTH_FAILED!!!"
    exit 1
}

puts "\[build_zynq\] Starting implementation ..."
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "!!!IMPL_FAILED!!!"
    exit 1
}
puts "\[build_zynq\] Bitstream done"

# --------------------------- 4. 导出硬件平台 .xsa ---------------------------
puts "\[build_zynq\] Exporting .xsa ..."
set xsa [file join $pdir $name "${name}.xsa"]
if {[catch {
    write_hw_platform -fixed -include_bit -force -file $xsa
} e]} {
    puts "\[build_zynq\] write_hw_platform failed, falling back to HDF: $e"
    write_sysdef -hwdef [get_files -quiet *.hdf] -bitfile [lindex [glob -nocomplain -directory [get_property DIRECTORY [get_runs impl_1]] *.bit] 0] -file $xsa
}

if {[file exists $xsa]} {
    puts "XSA=$xsa"
} else {
    puts "!!!NOXSA!!! Failed to generate .xsa"
}

set bit [glob -nocomplain -directory [get_property DIRECTORY [get_runs impl_1]] *.bit]
puts "BITSTREAM=$bit"
puts "PROJECT=$xpr"
close_project
puts "BUILD_ZYNQ_OK"
