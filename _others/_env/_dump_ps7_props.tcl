# -----------------------------------------------------------------------------
# 临时脚本：导出 processing_system7 的全部 CONFIG.* 属性名与默认值
# 用途：为生成 ACZ7015 PS7 Preset 提供权威参数名清单
# -----------------------------------------------------------------------------
set outfile "C:/Users/HUAWEI/Desktop/FPGA_26_9/_others/_env/_ps7_props.txt"

create_project -in_memory -part xc7z015clg485-2
create_bd_design sys
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

set cell [get_bd_cells processing_system7_0]
set fp [open $outfile w]
puts $fp "# processing_system7_v5_5 all CONFIG.* properties"
foreach p [lsort [list_property $cell]] {
    if {[string match "CONFIG.*" $p]} {
        if {[catch {set v [get_property $p $cell]} err]} { set v "<ERR>" }
        puts $fp "$p\t$v"
    }
}
close $fp
puts "WROTE $outfile"
puts "DONE"
