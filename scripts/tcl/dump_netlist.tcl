# dump_netlist.tcl -- 导出综合后网表(保留层次) + 统计寄存器
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp

# 统计各类触发器数量
foreach t {FDRE FDSE FDCE FDPE LUT6 LUT5 LUT4 LUT3 LUT2} {
    set n [llength [get_cells -hier -quiet -filter "REF_NAME =~ $t*"]]
    puts "COUNT $t = $n"
}

# 找带 video 字样的任何 cell / net
set v [get_cells -hier -quiet -filter {NAME =~ *video*}]
puts "VIDEO_CELLS = [llength $v]"
foreach c $v { puts "  VC: $c" }
set vn [get_nets -hier -quiet -filter {NAME =~ *video*}]
puts "VIDEO_NETS = [llength $vn]"
foreach n $vn { puts "  VN: $n" }

# 找 axi_lite_slave 层次 (如果没被压平)
set s [get_cells -hier -quiet -filter {NAME =~ *axi_slv* || NAME =~ *axi_lite*}]
puts "SLAVE_CELLS = [llength $s]"
foreach c $s { puts "  SC: $c" }

write_verilog -force -hierarchy $out
puts "WROTE $out"
