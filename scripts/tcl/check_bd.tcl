set xpr [lindex $argv 0]
open_project $xpr
set bd [get_files -quiet system.bd]
open_bd_design $bd
puts "\[chk\] u_ila_hdmi 存在? [llength [get_bd_cells -quiet u_ila_hdmi]]"
if {[get_bd_cells -quiet u_ila_hdmi] ne ""} {
    puts "\[chk\]   MON_TYPE = [get_property CONFIG.C_MONITOR_TYPE [get_bd_cells u_ila_hdmi]]"
    puts "\[chk\]   PROBE0_W = [get_property CONFIG.C_PROBE0_WIDTH [get_bd_cells u_ila_hdmi]]"
}
puts "\[chk\] top1_0/debug_probe 宽度 = [get_property LEFT [get_bd_pins top1_0/debug_probe]] down to [get_property RIGHT [get_bd_pins top1_0/debug_probe]]"
puts "\[chk\] u_ila_vdma_mm2s 存在? [llength [get_bd_cells -quiet u_ila_vdma_mm2s]]"
if {[catch {validate_bd_design} e]} { puts "\[chk\] validate 失败: $e" } else { puts "\[chk\] validate OK" }
catch { close_bd_design }
close_project
puts "\[chk\] DONE"
