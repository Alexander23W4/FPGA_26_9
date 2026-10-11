# =============================================================================
#  ila_probe.tcl -- 正确关联探针文件, 并列出两个 ILA 的全部探针名
#
#  ★ 修正了我之前 ila_capture.tcl 的两个 bug:
#     1) 少了 refresh_hw_device  => 用的是过期器件记录 => 误报 "ILA cores found: 0"
#     2) 没设 PROBES.FILE        => 抓到了也认不出哪根线是什么
#
#  用法:
#    vivado -mode batch -notrace -nojournal -nolog \
#      -source scripts/tcl/ila_probe.tcl -tclargs <bit> <ltx>
# =============================================================================

set bit [lindex $argv 0]
set ltx [lindex $argv 1]

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

set dev [lindex [get_hw_devices xc7z015*] 0]
puts "DEVICE = $dev"
current_hw_device $dev

# ★ 关键: 关联探针文件 + 刷新 (顺序不能反)
if {$ltx ne "" && [file exists $ltx]} {
    if {[catch {set_property PROBES.FILE $ltx $dev} e]} { puts "PROBES.FILE 设置失败: $e" } else { puts "PROBES.FILE = $ltx" }
}
if {$bit ne "" && [file exists $bit]} {
    if {[catch {set_property FULL_PROBES.FILE $ltx $dev} e]} {}
}
if {[catch {refresh_hw_device -update_hw_probes true $dev} e]} { puts "refresh 失败: $e" } else { puts "refresh OK" }

puts "============================================================"
puts "ILA 列表: [get_hw_ilas -quiet]"
puts "============================================================"

foreach il [get_hw_ilas -quiet] {
    puts ""
    puts "---- $il ----"
    set probes [get_hw_probes -quiet -of_objects $il]
    puts "  探针数: [llength $probes]"
    foreach p $probes {
        set nm  [get_property NAME  $p]
        set wd  [get_property WIDTH $p]
        puts [format "    %-40s width=%s" $nm $wd]
    }
}

puts ""
puts "DONE"
