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

        # ---- 3) AXI VDMA (MM2S)：DDR -> AXI-Stream ----
        # 数据方向：axi_vdma_0(M_AXI_MM2S) -> axi_ic_hp(S01) -> PS S_AXI_HP0 -> DDR
        # 控制口 S_AXI_LITE 挂在 PS 的 M_AXI_GP0 上（lappend 进 gp_slaves），
        # PS 用它配 VSIZE/HSIZE/STRIDE/START_ADDRESS 并启动。
        #
        # ★ M_AXIS_MM2S 是流出口，【这里故意不接】—— 你的 PL 算法模块以后接在这里。
        #   不接的后果：tready 没人驱动 = 背压，VDMA 搬一点点就停住，帧计数不前进。
        #   链路本身是通的，只是下游暂时没人收数据，这是预期现象。
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma_0
        if {[catch {
            set_property -dict [list \
                CONFIG.c_include_s2mm            {1} \
                CONFIG.c_include_mm2s            {1} \
                CONFIG.c_num_fstores             {4} \
                CONFIG.c_addr_width              {32} \
                CONFIG.c_m_axi_mm2s_data_width   {64} \
                CONFIG.c_m_axis_mm2s_tdata_width {64} \
                CONFIG.c_include_mm2s_dre        {1} \
            ] [get_bd_cells axi_vdma_0]
        } _vd_cfg_err]} {
            puts "\[ACZ7015\] ERROR: could not configure axi_vdma_0: $_vd_cfg_err"
            error "axi_vdma_0 configuration failed"
        }
        lappend gp_slaves axi_vdma_0

        # ★ 这 6 个配置/状态寄存器【不引出到顶层引脚】。
        #
        # 曾经用 create_bd_port 引出去，结果顶层变成 396 个 IO，place 直接失败：
        #     ERROR: [Place 30-415] IO Placement failed due to overutilization.
        #     This design contains 396 I/O ports
        # 光一条 AXI4 从口(S_AXI_IMG)就 250+ 根，再加 6x32bit 就 400+，
        # 而 xc7z015clg485 根本没有这么多用户 IO。
        #
        # 正确做法：你的 PL 模块加在【BD 内部】，直接在 BD 里接这些引脚，
        # 不需要经过顶层引脚。GPIO cell 都保留着，加模块时连上即可：
        #     axi_gpio_out0/gpio_io_o   -> img_base
        #     axi_gpio_out0/gpio2_io_o  -> img_geom
        #     axi_gpio_out1/gpio_io_o   -> img_fmt
        #     axi_gpio_out1/gpio2_io_o  -> img_ctrl
        #     axi_gpio_in0/gpio_io_i    <- img_status
        #     axi_gpio_in0/gpio2_io_i   <- img_area
    }

    # ---- 控制通路 AXI Interconnect（PS 当主）----
    set nm [llength $gp_slaves]

    # PL 顶层 rtl/top1.v（里面自带 axi_lite_rcv + 整条图像通路）。
    # 它的子模块都齐了才多留一个 MI 口（M04_AXI）给它。
    set _pl_rtl [list \
        [file normalize [file join $repo_root rtl axi_lite_rcv.v]] \
        [file normalize [file join $repo_root rtl img2buf.v]] \
        [file normalize [file join $repo_root rtl bufback.v]] \
        [file normalize [file join $repo_root rtl frame_buf.v]] \
        [file normalize [file join $repo_root rtl axis_rcv.v]] \
        [file normalize [file join $repo_root rtl axis_out.v]] \
        [file normalize [file join $repo_root rtl top1.v]]]
    set _pl_ok 1
    foreach _f $_pl_rtl {
        if {![file exists $_f]} {
            puts "\[ACZ7015\] WARNING: 缺少 [file tail $_f]"
            set _pl_ok 0
        }
    }
    # 只有 -hp（有 axi_vdma_0）时才接 top1，否则它的两个流口没人接
    set _pl_en [expr {$_pl_ok && $want_hp}]
    set nmi   [expr {$nm + $_pl_en}]

    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
    set_property -dict [list CONFIG.NUM_MI $nmi CONFIG.NUM_SI {1}] [get_bd_cells axi_interconnect_0]

    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_interconnect_0/ACLK]
    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_interconnect_0/S00_ACLK]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN]
    connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]

    for {set i 0} {$i < $nm} {incr i} {
        set c  [lindex $gp_slaves $i]
        set mm [format "M%02d" $i]
        # 从口接口名也不统一：axi_gpio 是 S_AXI，axi_vdma 是 S_AXI_LITE。
        # 写死 S_AXI 的话，加 VDMA 时这里会报 "Arguments ... cannot be empty"。
        if {[get_bd_intf_pins -quiet $c/S_AXI] ne ""} {
            set _saxi S_AXI
        } else {
            set _saxi S_AXI_LITE
        }
        connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/${mm}_AXI] [get_bd_intf_pins $c/$_saxi]
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_interconnect_0/${mm}_ACLK]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/${mm}_ARESETN]
        # 从口的时钟/复位引脚名各 IP、各版本都不一样，逐个探测，别写死：
        #   axi_gpio : s_axi_aclk      / s_axi_aresetn
        #   axi_vdma : s_axi_lite_aclk / axi_resetn     (2023.2 的 v6.3 只有一个 axi_resetn)
        # 写死的话，加一个 IP 就会报 "Arguments ... cannot be empty" 或引脚不存在。
        set _aclk_pin ""
        foreach cand {s_axi_aclk s_axi_lite_aclk} {
            if {[get_bd_pins -quiet $c/$cand] ne ""} { set _aclk_pin $cand ; break }
        }
        set _arst_pin ""
        foreach cand {s_axi_aresetn s_axi_lite_aresetn axi_resetn} {
            if {[get_bd_pins -quiet $c/$cand] ne ""} { set _arst_pin $cand ; break }
        }
        if {$_aclk_pin eq "" || $_arst_pin eq ""} {
            error "cannot find clock/reset pins on $c (aclk='$_aclk_pin' arst='$_arst_pin')"
        }
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins $c/$_aclk_pin]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins $c/$_arst_pin]
    }

    # =========================================================================
    #  PL 顶层：rtl/top1.v
    #
    #      PS(M_AXI_GP0) -> axi_interconnect_0/S00_AXI
    #                          -> M04_AXI -> top1_0/S_AXI
    #
    #  top1 里面自己就有一个 axi_lite_rcv，所以 BD 里【只加 top1 这一个】，
    #  不要再单独加 axi_lite_rcv（那样同一个 0x44000000 会挂两个从机）。
    #
    #  top1 的 slave 看到的是【偏移】地址（interconnect 把基地址剥掉了）：
    #      awaddr = 0x000 / 0x010 / 0x020   (MODE / CMD / DATA)
    #
    #  top1 的 rst 是【高有效】，而 BD 只有低有效的 peripheral_aresetn，
    #  所以中间串一个反相器。
    # =========================================================================
    if {$_pl_en} {
        add_files -norecurse $_pl_rtl
        create_bd_cell -type module -reference top1 top1_0

        if {[get_bd_intf_pins -quiet top1_0/S_AXI] eq ""} {
            error "top1_0/S_AXI 接口没被推断出来（检查 top1.v 端口上的 X_INTERFACE_INFO）"
        }

        set _mm [format "M%02d" $nm]

        connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/${_mm}_AXI] \
                            [get_bd_intf_pins top1_0/S_AXI]
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0]                 [get_bd_pins axi_interconnect_0/${_mm}_ACLK]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/${_mm}_ARESETN]

        # 时钟
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins top1_0/clk]

        # 复位反相： peripheral_aresetn(低有效) -> top1_0/rst(高有效)
        create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 top1_rst_inv
        set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells top1_rst_inv]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins top1_rst_inv/Op1]
        connect_bd_net [get_bd_pins top1_rst_inv/Res]               [get_bd_pins top1_0/rst]

        puts "\[ACZ7015\] top1_0 -> axi_interconnect_0/${_mm}_AXI  (PL top, rst inverted)"
    } else {
        puts "\[ACZ7015\] WARNING: rtl/top1.v 或它的子模块缺失，BD 里没有 PL 逻辑"
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
    # S00 = AXI VDMA 的 M_AXI_MM2S（VDMA 从这里读 DDR）
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_ic_hp]

    # S_AXI_HP0 在 Zynq-7000 上是 AXI3 / 64bit，interconnect 负责协议转换
    connect_bd_intf_net [get_bd_intf_pins axi_ic_hp/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]

    # --- AXI VDMA memory WRITE port (S2MM) -> S01 : result image goes back to DDR ---
    if {[get_bd_pins -quiet axi_vdma_0/m_axi_s2mm_aclk] ne ""} {
        puts "\[ACZ7015\] Connecting AXI VDMA S2MM -> axi_ic_hp/S01_AXI -> PS S_AXI_HP0"
        connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_S2MM] \
                            [get_bd_intf_pins axi_ic_hp/S01_AXI]
    }

    # --- AXI VDMA 的内存读口接到 S00 ---
    # 注意：VDMA 的 s_axi_lite_aclk / axi_resetn 已经在上面 gp_slaves
    # 的循环里接过了，这里【不能】再接一次（重复连接会报错）。
    if {[get_bd_cells -quiet axi_vdma_0] ne ""} {
        puts "\[ACZ7015\] Connecting AXI VDMA MM2S -> axi_ic_hp/S00_AXI -> PS S_AXI_HP0"
        connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_MM2S] \
                            [get_bd_intf_pins axi_ic_hp/S00_AXI]
        # VDMA 有时钟域：内存/控制一个（m_axi_mm2s_aclk）+ 流一个（m_axis_mm2s_aclk）。
        # 全部给同一个 FCLK_CLK0。m_axis_mm2s_aclk 不接的话流那边根本不工作。
        # 复位由上面 gp_slaves 循环里的 axi_resetn 负责，这里不要重复接。
        foreach _cp {m_axi_mm2s_aclk m_axis_mm2s_aclk m_axi_s2mm_aclk s_axis_s2mm_aclk} {
            if {[get_bd_pins -quiet axi_vdma_0/$_cp] ne ""} {
                connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_vdma_0/$_cp]
            } else {
                puts "\[ACZ7015\] WARNING: axi_vdma_0/$_cp not found (skipped)"
            }
        }
    } else {
        puts "\[ACZ7015\] WARNING: axi_vdma_0 不存在，HP0 这条 Master 通路是空的"
    }

    # --- AXI4-Stream：VDMA <-> top1 -------------------------------------------
    #       VDMA MM2S --S_AXIS--> top1_0 --M_AXIS--> VDMA S2MM
    #   top1 内部：axis_rcv -> img2buf -> frame_buf -> bufback -> axis_out
    if {[get_bd_cells -quiet top1_0] ne ""} {

        if {[catch {
            connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] \
                                [get_bd_intf_pins top1_0/S_AXIS]
        } _e]} {
            puts "\[ACZ7015\] top1_0/S_AXIS 没被推断出来，逐根连"
            foreach {vp rp} {
                M_AXIS_MM2S_TDATA  s_axis_tdata
                M_AXIS_MM2S_TVALID s_axis_tvalid
                M_AXIS_MM2S_TREADY s_axis_tready
                M_AXIS_MM2S_TLAST  s_axis_tlast
                M_AXIS_MM2S_TKEEP  s_axis_tkeep
                M_AXIS_MM2S_TUSER  s_axis_tuser
            } {
                connect_bd_net [get_bd_pins axi_vdma_0/$vp] [get_bd_pins top1_0/$rp]
            }
        }

        if {[catch {
            connect_bd_intf_net [get_bd_intf_pins top1_0/M_AXIS] \
                                [get_bd_intf_pins axi_vdma_0/S_AXIS_S2MM]
        } _e]} {
            puts "\[ACZ7015\] top1_0/M_AXIS 没被推断出来，逐根连"
            foreach {sp dp} {
                m_axis_tdata  S_AXIS_S2MM_TDATA
                m_axis_tvalid S_AXIS_S2MM_TVALID
                m_axis_tready S_AXIS_S2MM_TREADY
                m_axis_tlast  S_AXIS_S2MM_TLAST
                m_axis_tkeep  S_AXIS_S2MM_TKEEP
                m_axis_tuser  S_AXIS_S2MM_TUSER
            } {
                connect_bd_net [get_bd_pins top1_0/$sp] [get_bd_pins axi_vdma_0/$dp]
            }
        }
        puts "\[ACZ7015\] top1_0: VDMA MM2S -> top1 -> VDMA S2MM"
    } else {
        puts "\[ACZ7015\] WARNING: top1_0 不存在，VDMA 两个流口悬空"
    }

    foreach p {ACLK S00_ACLK S01_ACLK M00_ACLK} {
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins axi_ic_hp/$p]
    }
    connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins $ps7/S_AXI_HP0_ACLK]
    foreach p {S00_ARESETN S01_ARESETN M00_ARESETN} {
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_ic_hp/$p]
    }
    # interconnect 自己的全局复位
    connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_ic_hp/ARESETN]

    # ★★ 这里【故意不再引任何顶层引脚】★★
    #
    # 之前把 S_AXI_IMG（一整条 AXI4 从口）+ FCLK_CLK0 + peripheral_aresetn
    # 引到顶层，结果 place_design 直接失败：
    #     ERROR: [Place 30-415] IO Placement failed due to overutilization.
    #     This design contains 396 I/O ports
    # 光一条 AXI4 从口的 araddr/wdata/rdata 就 250+ 根，xc7z015clg485 装不下。
    #
    # 你的 PL 模块是加在【BD 内部】的，需要时钟/复位就在 BD 里直接连
    #     $ps7/FCLK_CLK0  和  rst_ps7_50M/peripheral_aresetn
    # 数据入口连 axi_vdma_0/M_AXIS_MM2S。全部走内部网络，不占引脚。
}

# ----------------------------- 地址分配 -------------------------------------
if {$want_axi_infra} {
    assign_bd_address

    # ★ PL 的 AXI-Lite 从机（在 top1 里面）必须固定落在 0x44000000
    #   （PS 侧 pl_ctrl_test.c 里的 PL_CTRL_BASE 就是它，自动分配不会给这个地址）
    if {[get_bd_cells -quiet top1_0] ne ""} {
        set _seg [get_bd_addr_segs -quiet \
                     -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
                     -filter {NAME =~ "*top1*"}]
        if {$_seg ne ""} {
            set_property offset 0x44000000 $_seg
            puts [format "\[ACZ7015\] %s -> offset %s" \
                      [get_property NAME $_seg] [get_property offset $_seg]]
        } else {
            error "top1_0 没有分配到地址段，检查 S_AXI 接口"
        }
    }

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
