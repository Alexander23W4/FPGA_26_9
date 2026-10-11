# =============================================================================
#  incr_build.tcl —— 省时间的综合/实现流程
#
#  和 build_zynq.tcl 的区别 (就三点):
#    ① 不 reset_run synth_1   => Vivado 按源文件时间戳自己决定要不要重综合
#    ② 综合开 incremental=reuse (拿上次的 synth dcp 当参考)  —— 用 catch 包住,
#       属性名对不上也不会中断, 只是没开成增量而已
#    ③ 实现开 incremental_checkpoint (拿上次的 routed dcp 当参考)
#       => 布局布线大部分可以复用, 这是最省时间的一步
#
#  用法 (一般不用直接调, 用 scripts/build_incr.sh):
#    vivado -mode batch -source scripts/tcl/incr_build.tcl \
#           -tclargs <path/to/fpga_26.xpr> [jobs]
#
#  ★ 什么时候不要用增量:
#      改了 Block Design 结构 / 改了约束 / 增量后时序不收敛
#      => 那就退回普通流程: ./scripts/build.sh zynq -n fpga_26 -H
# =============================================================================

# ---------- 参数 ----------
if {[llength $argv] < 1} {
    puts "\[incr\] 用法: incr_build.tcl <xpr> \[jobs\]"
    exit 1
}
set xpr  [lindex $argv 0]
set jobs 8
if {[llength $argv] >= 2} { set jobs [lindex $argv 1] }

puts "\[incr\] ==============================================="
puts "\[incr\] xpr  = $xpr"
puts "\[incr\] jobs = $jobs"
puts "\[incr\] ==============================================="

# ---------- 打开已有工程 ----------
if {![file exists $xpr]} {
    puts "\[incr\] ✗ 工程不存在: $xpr"
    exit 1
}
open_project $xpr

# ---------- ① 不 reset synth_1, 直接交给 Vivado 判断 ----------
# (build_zynq.tcl 里那句 reset_run synth_1 就是慢的根源)
puts "\[incr\] 跳过 reset_run synth_1  (Vivado 会按时间戳决定是否重跑)"

# ---------- ② 综合开增量 (可选, 失败不影响) ----------
if {[catch {
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE} \
                 -value reuse -objects [get_runs synth_1]
    puts "\[incr\] synth_1 已开 incremental = reuse"
} err]} {
    puts "\[incr\] (综合增量没开成, 不影响: $err)"
}

# ---------- ③ 实现开增量: 参考上次的 routed dcp ----------
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set routed   [lsort [glob -nocomplain -directory $impl_dir *_routed.dcp]]
if {[llength $routed] > 0} {
    set ref [lindex $routed end]
    if {[catch {
        set_property incremental_checkpoint $ref [get_runs impl_1]
        puts "\[incr\] impl_1 增量参考: $ref"
    } err]} {
        puts "\[incr\] (实现增量没开成: $err)"
    }
} else {
    puts "\[incr\] 没有找到 *_routed.dcp, 实现走全量 (第一次跑增量时会这样)"
}

# ---------- ④ 跑综合 ----------
puts "\[incr\] ---------- synth_1 ----------"
set t0 [clock seconds]
# ★ Vivado 硬性要求: 源码改过的 run 必须先 reset 才能 launch
#   (否则报 ERROR: [Common 17-69] Run 'synth_1' needs to be reset)
#   实现阶段的 incremental_checkpoint 仍然保留 => 布局布线可以复用
puts "\[incr\] reset_run synth_1"
reset_run -quiet synth_1

if {[catch {launch_runs synth_1 -jobs $jobs} err]} {
    puts "\[incr\] ✗ launch synth 失败: $err"; exit 1
}
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "\[incr\] ✗ synth_1 失败 (状态: [get_property STATUS [get_runs synth_1]])"
    exit 1
}
puts "\[incr\] synth_1 完成, 用了 [expr {[clock seconds]-$t0}] 秒"

# ---------- ⑤ 跑实现到 bitstream ----------
puts "\[incr\] ---------- impl_1 ----------"
set t1 [clock seconds]
if {[catch {launch_runs impl_1 -to_step write_bitstream -jobs $jobs} err]} {
    puts "\[incr\] ✗ launch impl 失败: $err"; exit 1
}
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "\[incr\] ✗ impl_1 失败 (状态: [get_property STATUS [get_runs impl_1]])"
    exit 1
}
puts "\[incr\] impl_1 完成, 用了 [expr {[clock seconds]-$t1}] 秒"

# ---------- ⑥ 报告结果 ----------
set bit [file join $impl_dir system_wrapper.bit]
if {[file exists $bit]} {
    puts "\[incr\] ==============================================="
    puts "\[incr\] bitstream = $bit"
    puts "\[incr\] 时间戳    = [clock format [file mtime $bit] -format {%Y-%m-%d %H:%M:%S}]"
    # 时序: 尽量报一下 WNS (查不到就算了)
    if {[catch {
        set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
        puts "\[incr\] WNS       = $wns ns"
        if {$wns < 0} { puts "\[incr\] ⚠ 时序不收敛! 建议退回普通流程重跑" }
    } err]} {}
    puts "\[incr\] ==============================================="
    if {[catch {write_bitstream -force $bit} err]} {}   ;# 确保已写出
    close_project
    exit 0
} else {
    puts "\[incr\] ✗ 没找到 bitstream: $bit"
    close_project
    exit 1
}
