# =============================================================================
#  clear_incr.tcl —— 清掉 impl_1 上残留的 incremental_checkpoint 属性
#
#  背景:
#    incr_build.tcl 给 impl_1 设了
#      set_property incremental_checkpoint <impl_1 目录里的 *_routed.dcp>
#    而那个文件在 run 被 reset 时会被 Vivado 删掉。
#    属性本身却【留在工程里】, 于是之后任何 launch_runs impl_1 都会报:
#      ERROR: [Vivado 12-3280] Incremental checkpoint file '..._routed.dcp'
#             set on run 'impl_1' does not exist.
#
#  用法:
#    vivado -mode batch -notrace -source scripts/tcl/clear_incr.tcl \
#           -tclargs <path/to/fpga_26.xpr>
# =============================================================================

if {[llength $argv] < 1} {
    puts "\[clear\] 用法: clear_incr.tcl <xpr>"
    exit 1
}
set xpr [lindex $argv 0]
if {![file exists $xpr]} { puts "\[clear\] ✗ 工程不存在: $xpr"; exit 1 }

open_project $xpr

# ---- ① 清掉 incremental_checkpoint 属性 ----
if {[catch {
    set cur [get_property incremental_checkpoint [get_runs impl_1]]
    puts "\[clear\] 当前 incremental_checkpoint = '$cur'"
    set_property incremental_checkpoint "" [get_runs impl_1]
    puts "\[clear\] ✓ 已清空"
} err]} {
    puts "\[clear\] (清属性时出错, 继续: $err)"
}

# ---- ② 顺便把 impl_1 复位, 免得残留状态 ----
if {[catch {reset_run -quiet impl_1} err]} {
    puts "\[clear\] (reset impl_1 出错, 继续: $err)"
} else {
    puts "\[clear\] ✓ 已 reset impl_1"
}

# ---- ③ 确认 ----
if {[catch {
    puts "\[clear\] 复查 incremental_checkpoint = '[get_property incremental_checkpoint [get_runs impl_1]]'"
} err]} {}

close_project
puts "\[clear\] 完成。现在可以正常跑 ./scripts/build.sh zynq -n fpga_26 -H"
