# =============================================================================
#  run_sim.tcl —— Vivado xsim 仿真
# =============================================================================
#  由 scripts/build.sh sim 调用。
#  参数: <工程名> <工程目录> [测试平台顶层名]
#
#  若不存在仿真工程，会用 rtl/ 和 sim/tb/ 下的文件新建一个纯仿真工程。
# =============================================================================

set name [lindex $argv 0]
set pdir [lindex $argv 1]
set tb   [lindex $argv 2]

if {$name eq "" || $pdir eq ""} {
    puts "!!!ARGS!!! run_sim.tcl requires: <name> <projdir> [tb_top]"
    exit 1
}

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set rtl_dir    [file join $repo_root rtl]
set tb_dir     [file join $repo_root sim tb]
set xpr        [file join $pdir $name "${name}.xpr"]

puts "============================================================"
puts " \[run_sim\] $name"
puts "   Testbench   : [expr {$tb eq "" ? "(auto)" : $tb}]"
puts "============================================================"

# --------------------------- 1. 打开或新建仿真工程 --------------------------
if {[file exists $xpr]} {
    open_project $xpr
} else {
    file mkdir $pdir
    create_project $name [file join $pdir $name] -part xc7z015clg485-2 -force
    set_property target_language Verilog [current_project]
    if {[file isdirectory $rtl_dir]} {
        add_files -fileset sources_1 -norecurse [glob -nocomplain -directory $rtl_dir -types f *.sv *.v]
        foreach sub [glob -nocomplain -directory $rtl_dir -type d *] {
            add_files -fileset sources_1 -norecurse \
                [concat [glob -nocomplain -directory $sub -types f *.sv] \
                        [glob -nocomplain -directory $sub -types f *.v]]
        }
    }
}

# --------------------------- 2. 加入测试平台 --------------------------------
if {[file isdirectory $tb_dir]} {
    set tbfiles [concat \
        [glob -nocomplain -directory $tb_dir -types f *.sv] \
        [glob -nocomplain -directory $tb_dir -types f *.v]]
    if {[llength $tbfiles] > 0} {
        add_files -fileset sim_1 -norecurse $tbfiles
        puts "\[run_sim\] Testbench files: [llength $tbfiles]"
    }
}

# --------------------------- 3. 定顶层 --------------------------------------
if {$tb ne ""} {
    set_property top $tb [get_filesets sim_1]
} else {
    # 自动挑：sim/tb 下名字含 tb 的文件
    set found ""
    foreach f [get_files -quiet -of_objects [get_filesets sim_1]] {
        if {[string match "*tb*" [file tail $f]]} { set found [file rootname [file tail $f]]; break }
    }
    if {$found ne ""} {
        set_property top $found [get_filesets sim_1]
        puts "\[run_sim\] Auto-selected top: $found"
    }
}

set simtop [get_property top [get_filesets sim_1]]
if {$simtop eq ""} {
    puts "!!!NOTB!!! No testbench found. Specify it with -b <top>."
    close_project
    exit 1
}

# --------------------------- 4. 跑仿真 --------------------------------------
update_compile_order -fileset sim_1
puts "\[run_sim\] Running xsim, top = $simtop ..."

if {[catch {
    launch_simulation -mode behavioral
    run all
    puts "\[run_sim\] Simulation finished"
} e]} {
    puts "!!!SIM_FAILED!!! $e"
    close_sim -quiet
    close_project -quiet
    exit 1
}

# 找波形数据库
set wdb [glob -nocomplain -directory [get_property DIRECTORY [get_filesets sim_1]] *.wdb]
puts "WDB=$wdb"

close_sim -quiet
close_project -quiet
puts "SIM_OK"
