# =============================================================================
#  ila_capture2.tcl -- 武装两个 ILA 并抓取, 导出 CSV
#
#  ★ 修正了旧 ila_capture.tcl 的两个 bug:
#     1) 缺 refresh_hw_device  => 误报 "ILA cores found: 0"
#     2) 缺 PROBES.FILE        => 抓到了也认不出信号名
#
#  用法: vivado -mode batch -notrace -nojournal -nolog \
#          -source ila_capture2.tcl -tclargs <bit> <ltx> <outdir> [wait_sec]
# =============================================================================

set bit      [lindex $argv 0]
set ltx      [lindex $argv 1]
set outdir   [lindex $argv 2]
set wait_sec 45
if {[llength $argv] >= 4} { set wait_sec [lindex $argv 3] }

file mkdir $outdir

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

set dev [lindex [get_hw_devices xc7z015*] 0]
current_hw_device $dev
if {$ltx ne "" && [file exists $ltx]} { set_property PROBES.FILE $ltx $dev }
catch { set_property FULL_PROBES.FILE $ltx $dev }
refresh_hw_device -update_hw_probes true $dev

set ilas [get_hw_ilas -quiet]
puts "ILAS = $ilas"

foreach il $ilas {
    reset_hw_ila $il
    set_property CONTROL.DATA_DEPTH 4096 $il
    set_property CONTROL.TRIGGER_POSITION 512 $il

    # 找 awvalid 探针 -> 触发条件 awvalid == 1 (抓所有写事务)
    set awv [get_hw_probes -quiet -of_objects $il -filter {NAME =~ *awvalid*}]
    if {[llength $awv] > 0} {
        set_property TRIGGER_COMPARE_VALUE 1'b1 [lindex $awv 0]
        puts "  $il : trigger on [get_property NAME [lindex $awv 0]] == 1"
    } else {
        # Native ILA: 没有 awvalid, 用 "probe != 0" 兜底 -> 抓任意活动
        set all [get_hw_probes -quiet -of_objects $il]
        puts "  $il : no awvalid probe, arming with default trigger ([llength $all] probes)"
    }
    if {[catch {run_hw_ila $il} e]} { puts "  $il : run_hw_ila 失败: $e" }
}

puts "ARMED -- 现在请发送 V 2 (等 ${wait_sec}s)"
set waited 0
while {$waited < $wait_sec} {
    after 1000
    incr waited
    set allDone 1
    foreach il $ilas {
        if {[catch {set st [get_property CONTROL.CAPTURE_STATUS $il]} e]} { continue }
        if {$st eq "WAITING_FOR_TRIGGER"} { set allDone 0 }
    }
    if {$allDone} { break }
}
puts "waited ${waited}s"

set n 0
foreach il $ilas {
    incr n
    catch {set st [get_property CONTROL.CAPTURE_STATUS $il]}
    puts "---- $il  status=$st ----"
    if {[catch {upload_hw_ila_data $il} e]} { puts "  upload 失败: $e"; continue }
    if {[catch {
        set data [current_hw_ila_data]
        write_hw_ila_data -csv_file [file join $outdir "ila${n}.csv"] $data
        puts "  导出: [file join $outdir ila${n}.csv]"
    } e]} { puts "  导出失败: $e" }

    # 直接把探针值打出来 (取第一条样本)
    foreach p [get_hw_probes -quiet -of_objects $il] {
        if {[catch {
            set nm [get_property NAME $p]
            set wd [get_property WIDTH $p]
            set v  [get_property INPUT_PIPE $p]
            puts [format "    %-58s w=%s" $nm $wd]
        } e]} {}
    }
}
puts "DONE"
