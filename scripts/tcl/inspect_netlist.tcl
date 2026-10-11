# inspect_netlist.tcl -- 只读: 查综合后的网表里 0x10/0x14 的译码和寄存器在不在
set dcp [lindex $argv 0]
open_checkpoint $dcp

puts "===== 1) axi_lite_slave 实例 ====="
set cells [get_cells -hier -quiet -filter {NAME =~ *u_axi_slv*}]
puts "  slave cells: [llength $cells]"
foreach c $cells { puts "    $c" }

puts "===== 2) reg_video_mode 寄存器 ====="
set r [get_cells -hier -quiet -filter {NAME =~ *reg_video_mode*}]
puts "  found: [llength $r]"
foreach c $r { puts "    $c  [get_property REF_NAME [get_cells $c]]" }

puts "===== 3) reg_threshold / lesion 相关 ====="
foreach pat {*reg_threshold* *lesion* *reg_cmd* *reg_mode*} {
    set r [get_cells -hier -quiet -filter "NAME =~ $pat"]
    puts "  $pat : [llength $r]"
    foreach c $r { puts "    $c" }
}

puts "===== 4) 该子模块里的所有寄存器 (FDRE/FDSE) ====="
set base [lindex $cells 0]
if {$base ne ""} {
    set ff [get_cells -quiet -hier -filter "NAME =~ $base* && (REF_NAME =~ FDRE* || REF_NAME =~ FDSE* || REF_NAME =~ FDCE* || REF_NAME =~ FDPE*)"]
    puts "  FFs under slave: [llength $ff]"
    foreach c $ff { puts "    $c" }
} else {
    puts "  找不到 slave 实例 -- 层次名可能被压平, 改成全局搜"
    set all [get_cells -hier -quiet -filter {NAME =~ *reg_* && (REF_NAME =~ FDRE* || REF_NAME =~ FDSE*)}]
    puts "  reg_* FFs global: [llength $all]"
    foreach c $all { puts "    $c" }
}
puts "===== DONE ====="
