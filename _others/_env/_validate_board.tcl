# =============================================================================
#  验证：板卡文件能否被 Vivado 识别
# =============================================================================
set repo "C:/Users/HUAWEI/Desktop/FPGA_26_9"
set out  "$repo/_others/_env/_tmp"
file mkdir $out
cd $out

puts "=== A. 注册板卡库 ==="
source "$repo/tools/register_board.tcl"

puts "=== B. 查询板卡 ==="
set brds [get_board_parts -quiet *acz7015*]
puts "FOUND_BOARDS=$brds"
if {$brds eq ""} { puts "!!!NO_BOARD!!!"; exit 1 }

puts "=== C. 板卡属性 ==="
foreach b $brds {
    puts "  part_name = [get_property PART_NAME $b]"
}

puts "=== D. 用板卡建工程 ==="
set bp [lindex $brds 0]
if {[catch {
    create_project -in_memory -part xc7z015clg485-2
    set_property board_part $bp [current_project]
    puts "BOARD_PART_SET_OK = $bp"
} e]} {
    puts "!!!BOARD_PART_FAILED!!! $e"
}

puts "=== E. 板卡接口 ==="
if {[catch {set ifs [get_board_components -quiet *]} e]} { set ifs "" }
puts "  components/ifaces: $ifs"

puts "=== F. 直接建板卡工程（含 PS7 预设测试）==="
if {[catch {
    create_bd_design boardtest
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0]
    puts "  PS7 created: $ps"
    puts "  DDR PARTNO = [get_property CONFIG.PCW_UIPARAM_DDR_PARTNO $ps]"
    puts "  BANK0      = [get_property CONFIG.PCW_PRESET_BANK0_VOLTAGE $ps]"
    puts "  BANK1      = [get_property CONFIG.PCW_PRESET_BANK1_VOLTAGE $ps]"
    puts "  MIO_TREE   = [get_property CONFIG.PCW_MIO_TREE_PERIPHERALS $ps]"
} e]} {
    puts "!!!BD_FAILED!!! $e"
}

puts "ALL_DONE"
