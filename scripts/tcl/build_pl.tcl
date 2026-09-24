# =============================================================================
#  build_pl.tcl —— 纯 PL 全流程：建工程(或打开) -> 综合 -> 实现 -> 位流
# =============================================================================
#  由 scripts/build.sh pl 调用，不直接使用。
#  参数: <工程名> <工程目录> [顶层模块名] [并行数]
# =============================================================================

set name   [lindex $argv 0]
set pdir   [lindex $argv 1]
set top    [lindex $argv 2]
set jobs   [lindex $argv 3]
if {$jobs eq ""} { set jobs 4 }

if {$name eq "" || $pdir eq ""} {
    puts "!!!ARGS!!! build_pl.tcl 需要: <工程名> <工程目录> [顶层] [并行数]"
    exit 1
}

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set rtl_dir    [file join $repo_root rtl]
set xdc_file   [file join $repo_root constrs acz7015 acz7015.xdc]
set xpr        [file join $pdir $name "${name}.xpr"]

puts "============================================================"
puts " \[build_pl\] $name"
puts "   工程目录 : $pdir"
puts "   顶层     : [expr {$top eq "" ? "(自动)" : $top}]"
puts "   并行数   : $jobs"
puts "============================================================"

# --------------------------- 1. 打开或新建工程 ------------------------------
if {[file exists $xpr]} {
    puts "\[build_pl\] 打开已有工程（增量构建）"
    open_project $xpr
} else {
    puts "\[build_pl\] 新建工程"
    set argv [list $name $pdir $top]
    source [file join $script_dir create_pl_project.tcl]
}

# --------------------------- 2. 确保 RTL 都在工程里 -------------------------
set added 0
if {[file isdirectory $rtl_dir]} {
    set existing [get_files -quiet -of_objects [get_filesets sources_1]]
    foreach f [glob -nocomplain -directory $rtl_dir -types f *.sv *.v *.svh *.vh] {
        if {[lsearch -exact $existing [file normalize $f]] < 0} {
            add_files -fileset sources_1 -norecurse $f
            incr added
        }
    }
    # 子目录也要扫
    foreach sub [glob -nocomplain -directory $rtl_dir -type d *] {
        foreach f [concat \
            [glob -nocomplain -directory $sub -types f *.sv] \
            [glob -nocomplain -directory $sub -types f *.v]] {
            if {[lsearch -exact $existing [file normalize $f]] < 0} {
                add_files -fileset sources_1 -norecurse $f
                incr added
            }
        }
    }
}
puts "\[build_pl\] 新增源文件: $added"

# --------------------------- 3. 约束 ----------------------------------------
set existing_c [get_files -quiet -of_objects [get_filesets constrs_1]]
if {![file exists $xdc_file]} {
    puts "\[build_pl\] ⚠ 未找到约束文件: $xdc_file"
} elseif {[lsearch -exact $existing_c [file normalize $xdc_file]] < 0} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "\[build_pl\] 已挂载约束: $xdc_file"
}

update_compile_order -fileset sources_1

# --------------------------- 4. 顶层 ----------------------------------------
if {$top ne ""} {
    set_property top $top [current_fileset]
} elseif {[get_property top [current_fileset]] eq ""} {
    # 自动挑一个：优先文件名含 top 的
    set cands [get_files -quiet -of_objects [get_filesets sources_1]]
    foreach f $cands {
        if {[string match "*top*" [file tail $f]]} {
            set_property top [file rootname [file tail $f]] [current_fileset]
            puts "\[build_pl\] 自动顶层: [get_property top [current_fileset]]"
            break
        }
    }
}
update_compile_order -fileset sources_1

if {[get_property top [current_fileset]] eq ""} {
    puts "!!!NOTOP!!! 未能确定顶层模块，请用 -t <顶层名> 指定"
    exit 1
}

# --------------------------- 5. 综合 / 实现 / 位流 --------------------------
puts "\[build_pl\] 开始综合 ..."
reset_run -quiet synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "!!!SYNTH_FAILED!!!"
    puts [exec cat [get_property DIRECTORY [get_runs synth_1]]/runme.log]
    exit 1
}
puts "\[build_pl\] 综合完成"

puts "\[build_pl\] 开始实现 ..."
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "!!!IMPL_FAILED!!!"
    exit 1
}
puts "\[build_pl\] 实现 + 位流完成"

# --------------------------- 6. 时序小结 ------------------------------------
set rpt [file join [get_property DIRECTORY [get_runs impl_1]] "${top}_timing_summary_routed.rpt"]
if {[file exists $rpt]} {
    set fp [open $rpt r]; set n 0
    while {[gets $fp line] >= 0 && $n < 15} { puts "   $line"; incr n }
    close $fp
}

# --------------------------- 7. 产物路径 ------------------------------------
set bit [glob -nocomplain -directory [get_property DIRECTORY [get_runs impl_1]] *.bit]
puts "BITSTREAM=$bit"
puts "PROJECT=$xpr"
close_project
puts "BUILD_PL_OK"
