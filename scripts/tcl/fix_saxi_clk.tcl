set xpr [lindex $argv 0]
open_project $xpr
set bd [get_files -quiet system.bd]
open_bd_design $bd
if {[get_bd_cells -quiet u_ila_saxi] eq ""} { puts "\[c\] u_ila_saxi 不存在"; close_project; exit 0 }
puts "\[c\] u_ila_saxi 的引脚: [get_bd_pins -quiet -of_objects [get_bd_cells u_ila_saxi]]"
foreach pn {clk resetn clk_1 resetn_1} {
    set p [get_bd_pins -quiet u_ila_saxi/$pn]
    if {$p ne ""} {
        set n [get_bd_nets -quiet -of_objects $p]
        puts "\[c\]   $pn  net = '$n'"
    } else { puts "\[c\]   $pn  (无此引脚)" }
}
if {[catch {
    set clkp [get_bd_pins -quiet u_ila_saxi/clk]
    if {$clkp ne ""} { connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] $clkp }
    set rp [get_bd_pins -quiet u_ila_saxi/resetn]
    if {$rp ne ""} { connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] $rp }
    puts "\[c\] 时钟/复位已接"
} e]} { puts "\[c\] 连接失败(可能已连): $e" }
if {[catch {validate_bd_design} e]} { puts "\[c\] validate 失败: $e" } else { puts "\[c\] validate OK" }
if {[catch {save_bd_design} e]} { puts "\[c\] save 失败: $e" } else { puts "\[c\] save OK" }
if {[catch {generate_target all [get_files $bd]} e]} { puts "\[c\] generate 失败: $e" } else { puts "\[c\] generate OK" }
close_bd_design
close_project
puts "\[c\] DONE"
