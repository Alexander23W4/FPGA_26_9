# =============================================================================
#  create_zynq_project.tcl  ——  Zynq（PS + PL）工程模板
# =============================================================================
#  用法：
#     vivado -mode batch -source tools/create_zynq_project.tcl -tclargs <工程名> [目标目录] [-axi] [-no_usb0] [-no_i2c0]
#
#  例：
#     vivado -mode batch -source tools/create_zynq_project.tcl -tclargs zynq_hello
#     vivado -mode batch -source tools/create_zynq_project.tcl -tclargs zynq_led D:/work -axi
#
#  生成内容：
#     <目录>/<工程名>/
#        <工程名>.xpr
#        <工程名>.srcs/sources_1/bd/system/system.bd      ← 已按 ACZ7015 配好 PS7
#        <工程名>.srcs/sources_1/bd/system/hdl/system_wrapper.v
#        <工程名>.srcs/constrs_1/imports/acz7015.xdc
#
#  默认 Block Design 内容：
#     · processing_system7   —— 套用 ACZ7015 板级预设
#                                 (QSPI / ENET0 / USB0 / SD0 / UART1 / I2C0 / GPIO)
#     · FCLK0 = 50 MHz
#     · DDR 与 FIXED_IO 引出为外部端口
#  加 -axi 还会自动生成：
#     · AXI Interconnect + Processor System Reset + AXI GPIO(8bit, 接板上 LED)
# =============================================================================

# ----------------------------- 参数解析 -------------------------------------
if {[llength $argv] < 1} {
    puts "用法: vivado -mode batch -source create_zynq_project.tcl -tclargs <工程名> \[目标目录\] \[-axi\] \[-no_usb0\] \[-no_i2c0\]"
    exit 1
}

set proj_name ""
set proj_dir  "C:/Users/HUAWEI/Desktop/FPGA_26_9/build"
set want_axi  0
set ps7_opts  [list]

foreach a $argv {
    switch -- $a {
        -axi     { set want_axi 1 }
        -no_usb0 { lappend ps7_opts -no_usb0 }
        -no_i2c0 { lappend ps7_opts -no_i2c0 }
        default  {
            if {$proj_name eq ""} { set proj_name $a } else { set proj_dir $a }
        }
    }
}
if {$proj_name eq ""} { error "必须指定工程名" }

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set preset_tcl [file normalize [file join $repo_root config acz7015_ps7_preset.tcl]]
set xdc_file   [file normalize [file join $repo_root config acz7015.xdc]]
set part_name  "xc7z015clg485-2"

puts "=============================================="
puts " ACZ7015 Zynq 工程创建"
puts "   工程名   : $proj_name"
puts "   目标目录 : $proj_dir"
puts "   器件     : $part_name"
puts "   AXI 外设 : [expr {$want_axi ? "是" : "否"}]"
puts "   PS7 开关 : $ps7_opts"
puts "=============================================="

# ----------------------------- 创建工程 -------------------------------------
file mkdir $proj_dir
create_project $proj_name [file join $proj_dir $proj_name] -part $part_name -force
set_property target_language Verilog [current_project]

# ----------------------------- 约束 -----------------------------------------
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "\[ACZ7015\] 已添加板级约束模板: $xdc_file"
}

# ----------------------------- Block Design ---------------------------------
puts "\[ACZ7015\] 创建 Block Design 'system' ..."
create_bd_design "system"

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

# ---- 套用 ACZ7015 板级预设 ----
source $preset_tcl
apply_acz7015_ps7_preset {*}$ps7_opts

# ---- DDR / FIXED_IO 引出 ----
set ps7 [get_bd_cells processing_system7_0]
foreach intf {DDR FIXED_IO} {
    set p [get_bd_intf_pins -quiet $ps7/$intf]
    if {$p ne ""} {
        if {[catch {make_bd_intf_pins_external $p}]} {
            puts "\[ACZ7015\] $intf 已经引出"
        }
    }
}

# ---- PS7 的 AXI 主口时钟回接 ----
# 无论是否使用 AXI 外设都必须接，否则 DRC 报 [BD 41-758]
set _aclk [get_bd_pins -quiet processing_system7_0/M_AXI_GP0_ACLK]
if {$_aclk ne ""} {
    if {[catch {connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] $_aclk} _e]} {
        puts "\[ACZ7015\] M_AXI_GP0_ACLK 已连接"
    }
}

# ---- 可选：AXI 基础设施 + LED GPIO ----
if {$want_axi} {
    puts "\[ACZ7015\] 生成 AXI 基础设施 ..."

    # 打开 M_AXI_GP0 与 FCLK
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 1 \
        CONFIG.PCW_FCLK_CLK0_BUF TRUE \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ 50 \
    ] $ps7

    # AXI Interconnect
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
    set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells axi_interconnect_0]

    # Processor System Reset
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_50M
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0]  [get_bd_pins rst_ps7_50M/slowest_sync_clk]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_50M/ext_reset_in]

    # AXI GPIO -> 板上 8 位 LED
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH  {8} \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_ALL_INPUTS  {0} \
        CONFIG.C_IS_DUAL     {0} \
    ] [get_bd_cells axi_gpio_led]

    # 时钟与复位
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/ACLK]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/S00_ACLK]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_interconnect_0/M00_ACLK]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_gpio_led/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn]   [get_bd_pins axi_interconnect_0/S00_ARESETN]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn]   [get_bd_pins axi_interconnect_0/M00_ARESETN]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn]   [get_bd_pins axi_gpio_led/s_axi_aresetn]

    # AXI 连接
    connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI]     [get_bd_intf_pins axi_gpio_led/S_AXI]

    # LED 引出为外部端口
    create_bd_port -dir O -from 7 -to 0 led
    connect_bd_net [get_bd_ports led] [get_bd_pins axi_gpio_led/gpio_io_o]

    # 分配地址
    assign_bd_address
}

# ---- 保存并校验 ----
regenerate_bd_layout
if {[catch {validate_bd_design} e]} {
    puts "\[ACZ7015\] validate_bd_design 提示: $e"
    puts "          （未连接的时钟/地址属正常，后续加 IP 后再校验）"
}

save_bd_design

# ---- 生成 wrapper 并设为顶层 ----
set wrapper [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=============================================="
puts " 工程创建完成"
puts "   $proj_dir/$proj_name/$proj_name.xpr"
puts ""
puts " 下一步："
puts "   1. 打开工程，在 Block Design 里继续加你的 IP"
puts "   2. 若要跑 PS 裸机：Generate Bitstream -> Export Hardware (.xsa)"
puts "      -> Vitis Classic 2023.2 建 Platform -> 建 Application"
puts "=============================================="
puts "DONE"
