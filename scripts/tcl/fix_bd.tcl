# fix_bd.tcl -- 回滚我上一步往 BD 里塞坏的东西: 删掉 u_ila_saxi, 恢复 BD
set xpr [lindex $argv 0]
open_project $xpr
set bd [get_files -quiet system.bd]
open_bd_design $bd

puts "\[fix\] --- 删除 u_ila_saxi ---"
if {[get_bd_cells -quiet u_ila_saxi] ne ""} {
    if {[catch {delete_bd_objs [get_bd_cells u_ila_saxi]} e]} { puts "\[fix\]   删除失败: $e" } else { puts "\[fix\]   已删除 u_ila_saxi" }
} else { puts "\[fix\]   u_ila_saxi 不存在" }

puts "\[fix\] --- 检查 u_ila_hdmi 的连线 ---"
if {[get_bd_cells -quiet u_ila_hdmi] ne ""} {
    foreach pn {clk probe0} {
        set p [get_bd_pins -quiet u_ila_hdmi/$pn]
        if {$p ne ""} {
            set nets [get_bd_nets -quiet -of_objects $p]
            puts "\[fix\]   u_ila_hdmi/$pn  nets = $nets"
        }
    }
}

puts "\[fix\] --- validate ---"
if {[catch {validate_bd_design} e]} { puts "\[fix\]   validate 失败: $e" } else { puts "\[fix\]   validate OK" }
if {[catch {save_bd_design} e]} { puts "\[fix\]   save 失败: $e" } else { puts "\[fix\]   save OK" }

puts "\[fix\] --- generate_target ---"
if {[catch {generate_target all [get_files $bd]} e]} { puts "\[fix\]   generate 失败: $e" } else { puts "\[fix\]   generate OK" }

catch { close_bd_design }
close_project
puts "\[fix\] DONE"
