# =============================================================================
#  验证 ACZ7015 PS7 Preset 是否合法
#  用法: vivado -mode batch -source _validate_preset.tcl
# =============================================================================
set repo   "C:/Users/HUAWEI/Desktop/FPGA_26_9"
set outdir "$repo/_others/_env/_tmp"
file mkdir $outdir
cd $outdir

puts "=== 1. 加载预设 ==="
source "$repo/config/acz7015_ps7_preset.tcl"

puts "=== 2. 建立测试 BD ==="
create_project -in_memory -part xc7z015clg485-2
create_bd_design sys
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

puts "=== 3. 应用预设 ==="
if {[catch {apply_acz7015_ps7_preset} err]} {
    puts "!!!APPLY_FAILED!!! $err"
    exit 1
}

puts "=== 4. 校验 BD（连接性错误可忽略，只看参数是否被接受）==="
if {[catch {validate_bd_design} err]} {
    puts "VALIDATE_NOTE: $err"
    puts "  （孤立 PS7 的时钟脚未连接属正常，不代表参数非法）"
} else {
    puts "VALIDATE_OK"
}

puts "=== 5. 导出实际生效的关键配置 ==="
set cell [get_bd_cells processing_system7_0]
foreach k {
    PCW_PRESET_BANK0_VOLTAGE PCW_PRESET_BANK1_VOLTAGE
    PCW_UIPARAM_DDR_PARTNO PCW_UIPARAM_DDR_BUS_WIDTH
    PCW_UIPARAM_DDR_DRAM_WIDTH PCW_UIPARAM_DDR_DEVICE_CAPACITY
    PCW_UIPARAM_DDR_FREQ_MHZ PCW_UIPARAM_DDR_SPEED_BIN
    PCW_DDR_RAM_HIGHADDR
    PCW_QSPI_PERIPHERAL_ENABLE PCW_QSPI_QSPI_IO
    PCW_ENET0_PERIPHERAL_ENABLE PCW_ENET0_ENET0_IO
    PCW_ENET0_GRP_MDIO_IO
    PCW_USB0_PERIPHERAL_ENABLE PCW_USB0_USB0_IO
    PCW_SD0_PERIPHERAL_ENABLE PCW_SD0_SD0_IO
    PCW_UART1_PERIPHERAL_ENABLE PCW_UART1_UART1_IO
    PCW_I2C0_PERIPHERAL_ENABLE PCW_I2C0_I2C0_IO
    PCW_GPIO_MIO_GPIO_ENABLE PCW_GPIO_EMIO_GPIO_ENABLE
    PCW_FPGA0_PERIPHERAL_FREQMHZ PCW_APU_PERIPHERAL_FREQMHZ
    PCW_MIO_TREE_PERIPHERALS PCW_MIO_TREE_SIGNALS
} {
    if {[catch {set v [get_property CONFIG.$k $cell]} e]} { set v "<读取失败>" }
    puts "  $k = $v"
}
puts "ALL_DONE"
