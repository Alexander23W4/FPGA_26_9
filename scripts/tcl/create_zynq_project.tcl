# =============================================================================
#  create_zynq_project.tcl  ——  Zynq（PS + PL）工程模板
# =============================================================================
#  用法：
#     vivado -mode batch -source scripts/tcl/create_zynq_project.tcl \
#            -tclargs <工程名> [目标目录] [选项...]
#
#  选项：
#     -axi              加 AXI 基础设施 + LED GPIO
#     -hp               加 PL 直取 DDR 的数据通路（隐含 -axi 的 AXI 基础设施）
#                       · PS7 打开 S_AXI_HP0（AXI3 / 64bit）
#                       · 一组 AXI GPIO 当配置寄存器（PL 侧就是几根普通线）
#                       · S_AXI_IMG / FCLK_CLK0 / peripheral_aresetn 引出为端口
#     -fclk0 <MHz>      FCLK_CLK0 频率，默认 50
#     -no_usb0          PS7 不开 USB0
#     -no_i2c0          PS7 不开 I2C0
#
#  例：
#     vivado -mode batch -source scripts/tcl/create_zynq_project.tcl \
#            -tclargs fpga_26 D:/work -hp -fclk0 100
#
#  默认 Block Design 内容：
#     · processing_system7   —— 套用 ACZ7015 板级预设
#     · DDR 与 FIXED_IO 引出为外部端口
#  加 -axi：AXI Interconnect + Processor System Reset + AXI GPIO(8bit, LED)
#  加 -hp ：见下面「-hp 生成的接口」一节
# =============================================================================

# ----------------------------- 参数解析 -------------------------------------
if {[llength $argv] < 1} {
    puts "Usage: create_zynq_project.tcl -tclargs <name> \[projdir\] \[-axi\] \[-hp\] \[-fclk0 <MHz>\] \[-no_usb0\] \[-no_i2c0\]"
    exit 1
}

set proj_name ""
set proj_dir  "C:/Users/HUAWEI/Desktop/FPGA_26_9/build"
set want_axi  0
set want_hp   0
set fclk0     50
set ps7_opts  [list]

set _i 0
while {$_i < [llength $argv]} {
    set a [lindex $argv $_i]
    switch -- $a {
        -axi     { set want_axi 1 }
        -hp      { set want_hp  1 }
        -fclk0   { incr _i ; set fclk0 [lindex $argv $_i] }
        -no_usb0 { lappend ps7_opts -no_usb0 }
        -no_i2c0 { lappend ps7_opts -no_i2c0 }
        default  {
            if {$proj_name eq ""} { set proj_name $a } else { set proj_dir $a }
        }
    }
    incr _i
}
if {$proj_name eq ""} { error "必须指定工程名" }

# -hp 需要 AXI 基础设施才能配寄存器
set want_axi_infra [expr {$want_axi || $want_hp}]

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set preset_tcl [file normalize [file join $repo_root board acz7015 ps7_preset.tcl]]
set xdc_file   [file normalize [file join $repo_root constrs "${proj_name}.xdc"]]
set part_name  "xc7z015clg485-2"

puts "=============================================="
puts " ACZ7015 Zynq project creation"
puts "   Project name : $proj_name"
puts "   Project dir  : $proj_dir"
puts "   Part         : $part_name"
puts "   AXI infra    : [expr {$want_axi_infra ? "yes" : "no"}]"
puts "   PL->DDR (HP) : [expr {$want_hp ? "yes" : "no"}]"
puts "   FCLK0        : ${fclk0} MHz"
puts "   PS7 options  : $ps7_opts"
puts "=============================================="

# ----------------------------- 创建工程 -------------------------------------
file mkdir $proj_dir
create_project $proj_name [file join $proj_dir $proj_name] -part $part_name -force
set_property target_language Verilog [current_project]

# ----------------------------- 约束 -----------------------------------------
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "\[ACZ7015\] Project constraints added: $xdc_file"
}

# ----------------------------- Block Design ---------------------------------
puts "\[ACZ7015\] Creating Block Design 'system' ..."
create_bd_design "system"

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0
set ps7 [get_bd_cells processing_system7_0]

# ---- 套用 ACZ7015 板级预设 ----
source $preset_tcl
apply_acz7015_ps7_preset {*}$ps7_opts

# ---- DDR / FIXED_IO 引出 ----
foreach intf {DDR FIXED_IO} {
    set p [get_bd_intf_pins -quiet $ps7/$intf]
    if {$p ne ""} {
        if {[catch {make_bd_intf_pins_external $p}]} {
            puts "\[ACZ7015\] $intf already external"
        }
    }
}

# ---- PS7 的 AXI 主口时钟回接 ----
# 无论是否使用 AXI 外设都必须接，否则 DRC 报 [BD 41-758]
set _aclk [get_bd_pins -quiet $ps7/M_AXI_GP0_ACLK]
if {$_aclk ne ""} {
    if {[catch {connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] $_aclk} _e]} {
        puts "\[ACZ7015\] M_AXI_GP0_ACLK already connected"
    }
}

# =============================================================================
#  AXI 基础设施（-axi / -hp）
# =============================================================================
set gp_slaves [list]

if {$want_axi_infra} {
    puts "\[ACZ7015\] Generating AXI infrastructure ..."

    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 1 \
        CONFIG.PCW_FCLK_CLK0_BUF TRUE \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk0 \
    ] $ps7

    # ---- Processor System Reset ----
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_50M
    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0]     [get_bd_pins rst_ps7_50M/slowest_sync_clk]
    connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins rst_ps7_50M/ext_reset_in]

    # ---- 1) LED GPIO（-axi）----
    if {$want_axi} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led
        set_property -dict [list \
            CONFIG.C_GPIO_WIDTH  {8} \
            CONFIG.C_ALL_OUTPUTS {1} \
            CONFIG.C_ALL_INPUTS  {0} \
            CONFIG.C_IS_DUAL     {0} \
        ] [get_bd_cells axi_gpio_led]
        create_bd_port -dir O -from 7 -to 0 led
        connect_bd_net [get_bd_ports led] [get_bd_pins axi_gpio_led/gpio_io_o]
        lappend gp_slaves axi_gpio_led
    }

    # ---- 2) 配置寄存器组（-hp）----
    # 每个 dual AXI GPIO 给 2 个 32bit 寄存器：
    #     ch1 -> 偏移 0x00   ch2 -> 偏移 0x08
    # PL 侧看到的就是几根普通 32bit 线，不需要懂 AXI。
    if {$want_hp} {
        foreach c {axi_gpio_out0 axi_gpio_out1} {
            create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $c
            set_property -dict [list \
                CONFIG.C_IS_DUAL       {1} \
                CONFIG.C_GPIO_WIDTH    {32} \
                CONFIG.C_GPIO2_WIDTH   {32} \
                CONFIG.C_ALL_OUTPUTS   {1} \
                CONFIG.C_ALL_INPUTS    {0} \
                CONFIG.C_ALL_OUTPUTS_2 {1} \
                CONFIG.C_ALL_INPUTS_2  {0} \
            ] [get_bd_cells $c]
            lappend gp_slaves $c
        }
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_in0
        set_property -dict [list \
            CONFIG.C_IS_DUAL       {1} \
            CONFIG.C_GPIO_WIDTH    {32} \
            CONFIG.C_GPIO2_WIDTH   {32} \
            CONFIG.C_ALL_OUTPUTS   {0} \
            CONFIG.C_ALL_INPUTS    {1} \
            CONFIG.C_ALL_OUTPUTS_2 {0} \
            CONFIG.C_ALL_INPUTS_2  {1} \
        ] [get_bd_cells axi_gpio_in0]
        lappend gp_slaves axi_gpio_in0

        # PS -> PL
        foreach {portname cell pin} {
            img_base axi_gpio_out0 gpio_io_o
            img_geom axi_gpio_out0 gpio2_io_o
            img_fmt  axi_gpio_out1 gpio_io_o
            img_ctrl axi_gpio_out1 gpio2_io_o
        } {
            create_bd_port -dir O -from 31 -to 0 $portname
            connect_bd_net [get_bd_ports $portname] [get_bd_pins $cell/$pin]
        }
        # PL -> PS
        foreach {portname cell pin} {
            img_status axi_gpio_in0 gpio_io_i
            img_area   axi_gpio_in0 gpio2_io_i
        } {
            create_bd_port -dir I -from 31 -to 0 $portname
            connect_bd_net [get_bd_ports $portname] [get_bd_pins $cell/$pin]
        }
    }

    # ---- 控制通路 AXI Interconnect（PS 当主）----
    set nm [llength $gp_slaves]
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
    set_property -dict [list CONFIG.NUM_MI $nm CONFIG.NUM_SI {1}] [get_bd_cells axi_interconnect_0]

    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_interconnect_0/ACLK]
    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_interconnect_0/S00_ACLK]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN]
    connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]

    for {set i 0} {$i < $nm} {incr i} {
        set c  [lindex $gp_slaves $i]
        set mm [format "M%02d" $i]
        connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/${mm}_AXI] [get_bd_intf_pins $c/S_AXI]
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_interconnect_0/${mm}_ACLK]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/${mm}_ARESETN]
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins $c/s_axi_aclk]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins $c/s_axi_aresetn]
    }
}

# =============================================================================
#  -hp 生成的接口（PL 直取 DDR 的数据通路）
# =============================================================================
#  数据方向：PL（AXI Master）--S_AXI_IMG--> axi_ic_hp --> PS S_AXI_HP0 --> DDR
#
#  引出到 wrapper 上的端口：
#     S_AXI_IMG            AXI4 从口，你的 AXI Master 接这里
#     FCLK_CLK0            ${fclk0} MHz，给 PL 逻辑当时钟
#     peripheral_aresetn   低有效复位，和 AXI 域同步
#     img_base/img_geom/img_fmt/img_ctrl    PS 写给你的 32bit 配置寄存器
#     img_status/img_area                  你回给 PS 的 32bit 状态寄存器
#
#  PS 侧看到的寄存器（基地址由 assign_bd_address 分配，代码里用 xparameters.h）：
#     axi_gpio_out0 : +0x00 IMG_BASE   +0x08 IMG_GEOM
#     axi_gpio_out1 : +0x00 IMG_FMT    +0x08 IMG_CTRL
#     axi_gpio_in0  : +0x00 IMG_STATUS +0x08 IMG_AREA
# =============================================================================
if {$want_hp} {
    puts "\[ACZ7015\] Enabling S_AXI_HP0 (PL master -> DDR) ..."

    set_property -dict [list \
        CONFIG.PCW_USE_S_AXI_HP0        {1} \
        CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    ] $ps7

    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_ic_hp]

    # S_AXI_HP0 在 Zynq-7000 上是 AXI3 / 64bit，interconnect 负责协议转换
    connect_bd_intf_net [get_bd_intf_pins axi_ic_hp/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]

    foreach p {ACLK S00_ACLK M00_ACLK} {
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_ic_hp/$p]
    }
    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins $ps7/S_AXI_HP0_ACLK]
    foreach p {S00_ARESETN M00_ARESETN} {
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_ic_hp/$p]
    }
    # interconnect 自己的全局复位
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_ic_hp/ARESETN]

    # --- S00 引出：你的 AXI Master 接这里 ---
    make_bd_intf_pins_external [get_bd_intf_pins axi_ic_hp/S00_AXI]
    set _p [get_bd_intf_ports -quiet -filter {NAME =~ "S00_AXI*"}]
    if {$_p ne ""} { set_property name S_AXI_IMG $_p }

    # --- 时钟与复位引出：给 PL 逻辑用 ---
    # ★ 这里不用 make_bd_pins_external：对已经连了内部网络的 FCLK_CLK0
    #   它不生效（实测端口根本没生成，而且不报错）。用 create_bd_port 显式做。
    create_bd_port -dir O -type clk FCLK_CLK0
    connect_bd_net [get_bd_ports FCLK_CLK0] [get_bd_pins $ps7/FCLK_CLK0]

    create_bd_port -dir O -type rst peripheral_aresetn
    connect_bd_net [get_bd_ports peripheral_aresetn] [get_bd_pins rst_ps7_50M/peripheral_aresetn]

    # 外部时钟端口必须关联外部 AXI 从口，
    # 否则报 [BD 41-2559] "AXI interface port /S_AXI_IMG is not associated to any clock port"
    if {[catch {
        set_property -dict [list \
            CONFIG.FREQ_HZ          [expr {$fclk0 * 1000000}] \
            CONFIG.ASSOCIATED_BUSIF {S_AXI_IMG} \
        ] [get_bd_ports FCLK_CLK0]
    } _e]} {
        puts "\[ACZ7015\] WARNING: could not configure FCLK_CLK0 port: $_e"
    }
    if {[catch {
        set_property -dict [list CONFIG.POLARITY {ACTIVE_LOW}] [get_bd_ports peripheral_aresetn]
    } _e]} {
        puts "\[ACZ7015\] WARNING: could not configure peripheral_aresetn port: $_e"
    }
}

# ----------------------------- 地址分配 -------------------------------------
if {$want_axi_infra} {
    assign_bd_address
    puts "\[ACZ7015\] Address map (PS view):"
    foreach seg [get_bd_addr_segs -quiet -filter {NAME =~ "*SEG_axi_gpio*"}] {
        puts [format "   %-56s %s" [get_property NAME $seg] [get_property OFFSET $seg]]
    }
}

# ---- 保存并校验 ----
regenerate_bd_layout
set _vd_err ""
if {[catch {validate_bd_design} _vd_err]} {
    puts "\[ACZ7015\] validate_bd_design reported: $_vd_err"
} else {
    puts "\[ACZ7015\] validate_bd_design: OK"
}

save_bd_design

# ---- 生成 wrapper 并设为顶层 ----
set wrapper [make_wrapper -files [get_files system.bd] -top]
add_files -norecurse $wrapper
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=============================================="
puts " Project created"
puts "   $proj_dir/$proj_name/$proj_name.xpr"
puts ""
if {$want_hp} {
    puts " Block Design ports for your RTL:"
    puts "   S_AXI_IMG           your AXI Master connects here"
    puts "   FCLK_CLK0           ${fclk0} MHz"
    puts "   peripheral_aresetn  active-low reset"
    puts "   img_base  img_geom  img_fmt  img_ctrl   (PS -> PL, 32bit each)"
    puts "   img_status  img_area                     (PL -> PS, 32bit each)"
}
puts " Next steps:"
puts "   1. Generate Bitstream -> Export Hardware (.xsa)"
puts "   2. Vitis Unified IDE 2023.2: create Platform -> create Application"
puts "=============================================="
puts "DONE"
