set xpr [lindex $argv 0]
open_project $xpr
set bd [get_files -quiet system.bd]
open_bd_design $bd

puts "\[ila2\] top1_0/debug_probe 宽度 = [get_property LEFT [get_bd_pins top1_0/debug_probe]]"
if {[get_bd_cells -quiet u_ila_hdmi] ne ""} {
    if {[catch {delete_bd_objs [get_bd_cells u_ila_hdmi]} e]} { puts "\[ila2\] 删除失败: $e" } else { puts "\[ila2\] 旧 ILA 已删" }
}
if {[catch {
    create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 u_ila_hdmi
    set_property -dict [list \
        CONFIG.C_MONITOR_TYPE       {Native} \
        CONFIG.C_ENABLE_ILA_AXI_MON {false} \
        CONFIG.C_DATA_DEPTH         {4096} \
        CONFIG.C_NUM_OF_PROBES      {1} \
        CONFIG.C_PROBE0_WIDTH       {128} \
    ] [get_bd_cells u_ila_hdmi]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins u_ila_hdmi/clk]
    connect_bd_net [get_bd_pins top1_0/debug_probe] [get_bd_pins u_ila_hdmi/probe0]
    puts "\[ila2\] ✓ Native + PROBE0_WIDTH=128 已建好并连接"
} e]} { puts "\[ila2\] 建 ILA 失败: $e" }
foreach k {CONFIG.C_MONITOR_TYPE CONFIG.C_PROBE0_WIDTH CONFIG.C_NUM_OF_PROBES CONFIG.C_DATA_DEPTH} {
    if {[get_bd_cells -quiet u_ila_hdmi] ne ""} { puts "\[ila2\]   $k = [get_property $k [get_bd_cells u_ila_hdmi]]" }
}
if {[catch {validate_bd_design} e]} { puts "\[ila2\] validate 失败: $e" } else { puts "\[ila2\] validate OK" }
if {[catch {save_bd_design} e]} { puts "\[ila2\] save 失败: $e" } else { puts "\[ila2\] save OK" }
if {[catch {generate_target all [get_files $bd]} e]} { puts "\[ila2\] generate 失败: $e" } else { puts "\[ila2\] generate OK" }
catch { close_bd_design }
close_project
puts "\[ila2\] DONE"
