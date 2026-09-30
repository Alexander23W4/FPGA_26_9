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
# ★ 板级引脚模板: 所有 PACKAGE_PIN / IOSTANDARD 都在这个文件里
#   (clk50M=L5, tmds_data_p[2:0]=K7/M8/N6, tmds_tx_p=T2 ...)。
#   create_pl_project.tcl 里本来就挂了它, zynq 流程之前漏了 —— 后果是
#   这些端口全都没有 LOC/IOSTANDARD, 实现时 place 直接报
#   [Place 30-379] "Output of OBUF instance ... is not driving any port"。
set board_xdc  [file normalize [file join $repo_root constrs acz7015 acz7015.xdc]]
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
# ---------------------------------------------------------------------------
# 注: 曾经试过 set_param board.repoPaths + set_property BOARD_PART 来给 bank 电压,
#     实测板级定义挂不上, 而且后来用"纯 -part"已成功出过位流(OBUFDS-only 测试),
#     所以这里保持最简: 只用 -part, 不再碰 BOARD_PART。
# ---------------------------------------------------------------------------
file mkdir $proj_dir
create_project $proj_name [file join $proj_dir $proj_name] -part $part_name -force
set_property target_language Verilog [current_project]

# ----------------------------- 约束 -----------------------------------------
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "\[ACZ7015\] Project constraints added: $xdc_file"
} else {
    puts "\[ACZ7015\] NOTE: $xdc_file 不存在（工程专用约束，可以缺省）"
}
if {[file exists $board_xdc]} {
    add_files -fileset constrs_1 -norecurse $board_xdc
    puts "\[ACZ7015\] Board constraints added: $board_xdc"
} else {
    error "板级约束缺失: $board_xdc —— 没有它所有引脚都没有 LOC/IOSTANDARD"
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

# =============================================================================
#  时钟源: 板载 50MHz 晶振 (clk50M, 引脚 L5) -> clk_wiz_0
#      clk_out1 = 25.2 MHz  (clk / pclk / 所有 AXI)
#      clk_out2 = 126 MHz   (pclk_x5, = 5 * clk_out1)
#  ★ 整条 PL 【所有】时钟都用 clk_out1, 只有 pclk_x5 用 clk_out2。
#  ★ 必须建在 M_AXI_GP0_ACLK 回接【之前】: 否则那条连接找不到 clk_wiz_0,
#    会被 catch 吞掉, 现象就是 M_AXI_GP0_ACLK 悬空 -> BD 41-758。
#  ★ clk50M 的引脚/时序约束在 constrs/acz7015/acz7015.xdc 里已有。
# =============================================================================
if {[get_bd_ports -quiet clk50M] eq ""} {
    create_bd_port -dir I clk50M
}
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
    CONFIG.PRIMITIVE                   {MMCM} \
    CONFIG.PRIM_IN_FREQ                {50.000} \
    CONFIG.MMCM_CLKIN1_PERIOD          {20.000} \
    CONFIG.MMCM_DIVCLK_DIVIDE          {5} \
    CONFIG.MMCM_CLKFBOUT_MULT_F        {63.000} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F       {25.000} \
    CONFIG.MMCM_CLKOUT1_DIVIDE         {5} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ  {25.2} \
    CONFIG.CLKOUT2_USED                {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ  {126.000} \
    CONFIG.USE_LOCKED                  {true} \
    CONFIG.USE_RESET                   {false} \
] [get_bd_cells clk_wiz_0]
connect_bd_net [get_bd_ports clk50M] [get_bd_pins clk_wiz_0/clk_in1]
puts "\[ACZ7015\] clk_wiz_0: 50MHz -> clk_out1 25.2MHz / clk_out2 126MHz"

# ---- PS7 的 AXI 主口时钟回接 ----
# 无论是否使用 AXI 外设都必须接，否则 DRC 报 [BD 41-758]
set _aclk [get_bd_pins -quiet $ps7/M_AXI_GP0_ACLK]
if {$_aclk ne ""} {
    if {[catch {connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] $_aclk} _e]} {
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

    # (clk50M 端口 + clk_wiz_0 已经在上面建好 —— M_AXI_GP0_ACLK 回接要先用到它)

    # ---- Processor System Reset ----
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_50M
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]     [get_bd_pins rst_ps7_50M/slowest_sync_clk]
    connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins rst_ps7_50M/ext_reset_in]
    # ★ MMCM 未锁定前把复位按住: clk_wiz_0/locked -> proc_sys_reset/dcm_locked
    #   否则上电初期 clk_out1 还没稳, PL 会跑在乱时钟上, TMDS 吐垃圾电平。
    connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins rst_ps7_50M/dcm_locked]

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
        # ★ 修 MM2S "64bit beat 高 32 位恒为 0" 的问题 —— 第五条路, 也是唯一
        #   还没有被实测排除的那条。
        #
        #   已实测排除的: AFI0 写 3 (无效)、关 DRE (无效)、开 Store-and-Forward
        #   (无效)、AXI 通路数据位宽 (日志里只有 ID 位宽告警, 没有数据位宽告警,
        #   也没有插入 upsizer)。tkeep 也一直全 1 (tkeep_bad=0)。
        #
        #   剩下唯一没被解释的事实: MM2S 声明 64 位流, 实际只吐低 32 位真数据、
        #   高 32 位恒 0 (端口级标志 hi32_seen 始终为 0)。这【恰好就是它的内部
        #   流路径实际是 32 位】会有的表现。
        #
        #   所以把流侧配成 32 位。难点: IP 内部有自动推导
        #       calc_mm2s_tdata_width(流侧<=32) => 内存侧 = 32
        #   而内存侧合法值只有 64/128/256/512/1024, 直接设流侧=32 会连带把内存侧
        #   推成非法的 32 (这条之前实测失败过)。
        #   Tcl 的 -dict 是按【顺序】处理的, 所以把【流侧放在前面】、
        #   【内存侧放在后面】显式覆盖回去 —— 最终: 流侧 32 / 内存侧 64。
        #   这样 VDMA 每拍读一个 32bit 字、两拍拼成一个 64bit 流拍, 数据就是全的。
        #   PL 侧 pl_img_top / axis_rx_8b 的 TDATA_W 也是 32, 一拍 4 个 8bit 像素
        #   (256 字节/行 -> 64 拍/行 -> 16384 拍/帧)。
        #   (若这次仍失败, 就只剩 ILA 直接看 m_axi_mm2s 的 rdata 了。)
        if {[catch {
            set_property -dict [list \
                CONFIG.c_include_s2mm            {0} \
                CONFIG.c_include_mm2s            {1} \
                CONFIG.c_num_fstores             {4} \
                CONFIG.c_addr_width              {32} \
                CONFIG.c_m_axis_mm2s_tdata_width {32} \
                CONFIG.c_m_axi_mm2s_data_width   {64} \
                CONFIG.c_include_mm2s_dre        {0} \
            ] [get_bd_cells axi_vdma_0]
        } _vd_cfg_err]} {
            puts "\[ACZ7015\] ERROR: could not configure axi_vdma_0: $_vd_cfg_err"
            error "axi_vdma_0 configuration failed"
        }
        # ★ 单独一段设置 Store and Forward, 不放进上面那个 dict:
        #   万一某个 IP 版本不认这个名字, 只告警, 不拖垮整个构建。
        #   (已核对 axi_vdma_v6_3 的 component.xml: c_include_mm2s_sf 是 resolve=user
        #    的参数, 显示名 "Enable Store and Forward", 合法值 0/1, 默认 0。)
        if {[catch {
            set_property CONFIG.c_include_mm2s_sf {1} [get_bd_cells axi_vdma_0]
            puts "\[ACZ7015\] axi_vdma_0: c_include_mm2s_sf = 1 (MM2S Store and Forward 打开)"
        } _sf_err]} {
            puts "\[ACZ7015\] WARNING: could not set c_include_mm2s_sf: $_sf_err"
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

    # PL 唯一顶层: rtl/top1.v
    #   内部: axi2px -> denose -> hdl_out -> double_buf -> hdmi_out -> hdmi_tx
    #         以及 axi_lite_rcv 给 PS 做控制/状态
    #   它带一个 AXI-Lite 从口(S_AXI), 所以要多占 axi_interconnect_0 的一个 MI 口。
    set _pl_rtl [list \
        [file normalize [file join $repo_root rtl top1.v]] \
        [file normalize [file join $repo_root rtl axi_lite_rcv.v]] \
        [file normalize [file join $repo_root rtl axi2px.v]] \
        [file normalize [file join $repo_root rtl hdl_out.v]] \
        [file normalize [file join $repo_root rtl hdmi_out.v]] \
        [file normalize [file join $repo_root rtl double_buf.v]] \
        [file normalize [file join $repo_root rtl hdmi_tx.v]] \
        [file normalize [file join $repo_root rtl denose.v]] \
        [file normalize [file join $repo_root rtl denose_denoise.v]] \
        [file normalize [file join $repo_root rtl denose_denoise_q_RAM_AUTO_1R1W.v]] \
        [file normalize [file join $repo_root rtl denose_denoise_rear_frame_RAM_AUTO_1R1W.v]]]
    set _pl_ok 1
    foreach _f $_pl_rtl {
        if {![file exists $_f]} {
            puts "\[ACZ7015\] WARNING: 缺少 [file tail $_f]"
            set _pl_ok 0
        }
    }
    # 只有 -hp（有 axi_vdma_0）时才接 top1，否则它的 AXI-Stream 从口没人接
    set _pl_en [expr {$_pl_ok && $want_hp}]
    # top1 带 AXI-Lite 从口, 要多占一个 MI 口
    set nmi   [expr {$nm + $_pl_en}]

    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
    set_property -dict [list CONFIG.NUM_MI $nmi CONFIG.NUM_SI {1}] [get_bd_cells axi_interconnect_0]

    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_interconnect_0/ACLK]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_interconnect_0/S00_ACLK]
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
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_interconnect_0/${mm}_ACLK]
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
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $c/$_aclk_pin]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins $c/$_arst_pin]
    }

    # =========================================================================
    #  PL 顶层: rtl/top1.v
    #      PS(M_AXI_GP0) -> axi_interconnect_0/S00_AXI -> M0x_AXI -> top1_0/S_AXI
    #  top1 的 rst 是【高有效】，BD 只有低有效的 peripheral_aresetn, 串一个反相器。
    #  时钟统一: clk / pclk 都接 clk_wiz_0/clk_out1 (25.2MHz), pclk_x5 接 clk_out2。
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
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]             [get_bd_pins axi_interconnect_0/${_mm}_ACLK]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/${_mm}_ARESETN]

        # 时钟 (全部 clk_wiz_0/clk_out1 = 25.2MHz)
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins top1_0/clk]

        # 复位反相: peripheral_aresetn(低有效) -> top1_0/rst(高有效)
        create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 pl_rst_inv
        set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells pl_rst_inv]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins pl_rst_inv/Op1]
        connect_bd_net [get_bd_pins pl_rst_inv/Res]                 [get_bd_pins top1_0/rst]

        puts "\[ACZ7015\] top1_0 -> axi_interconnect_0/${_mm}_AXI (PL top, rst inverted)"
    } else {
        puts "\[ACZ7015\] WARNING: rtl/top1.v 或它的子模块缺失，BD 里没有 PL 逻辑"
    }

    # =========================================================================
    #  HDMI 控制器: 输出 -> 板上 HDMI_2 (J7) 的原生 TMDS 引脚
    #
    #  引脚约束已经在 constrs/acz7015/acz7015.xdc 里写好了(端口名一致):
    #      tmds_data_p[2]  K7      tmds_data_p[1]  M8
    #      tmds_data_p[0]  N6      tmds_tx_p      T2      (IOSTANDARD TMDS_33)
    #  差分对 N 端由 OBUFDS 自动配对, XDC 里不用单列。
    #
    #  ★ 输入(pclk / pclk_x5 / rst / vid_r / vid_g / vid_b / vid_hs / vid_vs /
    #    vid_de)按你的要求【留空】, 你自己在 BD 里接。
    # =========================================================================
    set _hdmi_rtl [file normalize [file join $repo_root rtl hdmi_tx.v]]
    if {[file exists $_hdmi_rtl]} {
        # hdmi_tx 已经实例化在 top1 里面, 这里【不再单独建 cell】,
        # 只把顶层 TMDS 端口建出来, 由 top1_0 驱动。
        create_bd_port -dir O -from 2 -to 0 tmds_data_p
        create_bd_port -dir O -from 2 -to 0 tmds_data_n
        create_bd_port -dir O                   tmds_tx_p
        create_bd_port -dir O                   tmds_tx_n
        connect_bd_net [get_bd_pins top1_0/tmds_data_p] [get_bd_ports tmds_data_p]
        connect_bd_net [get_bd_pins top1_0/tmds_data_n] [get_bd_ports tmds_data_n]
        connect_bd_net [get_bd_pins top1_0/tmds_tx_p]  [get_bd_ports tmds_tx_p]
        connect_bd_net [get_bd_pins top1_0/tmds_tx_n]  [get_bd_ports tmds_tx_n]

        puts "\[ACZ7015\] hdmi_tx_0: TMDS 输出 -> tmds_data_p[2:0] / tmds_tx_p (板上 HDMI_2 J7)"
        puts "\[ACZ7015\]          输入 pclk/pclk_x5/rst/vid_* 留空, 待接"
    } else {
        puts "\[ACZ7015\] WARNING: rtl/hdmi_tx.v 缺失，BD 里没有 HDMI 控制器"
    }

    # =========================================================================
    #  时钟: 整条 PL 统一用 clk_wiz_0/clk_out1 (25.2MHz)
    #  (clk50M 端口 + clk_wiz_0 已在上面 AXI 基础设施之前建好)
    # =========================================================================
    if {[get_bd_cells -quiet top1_0] ne ""} {
        # 注意: top1_0/clk 已经在建 cell 那一段接过了, 这里【不能】再接一次。
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins top1_0/pclk]
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins top1_0/pclk_x5]
        puts "\[ACZ7015\] clk_wiz_0: clk_out1(25.2M) -> top1_0/clk + top1_0/pclk"
        puts "\[ACZ7015\]             clk_out2(126M)  -> top1_0/pclk_x5"
    } else {
        puts "\[ACZ7015\] clk_wiz_0 已建好; top1_0 还没加进 BD, 待接"
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
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_ic_hp]

    # S_AXI_HP0 在 Zynq-7000 上是 AXI3 / 64bit，interconnect 负责协议转换
    connect_bd_intf_net [get_bd_intf_pins axi_ic_hp/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]

    # --- VDMA S2MM (回写通道) 已废弃 ---
    # 结果由 PL 直接走 HDMI 输出, 不再回写 DDR: axi_vdma_0 的 c_include_s2mm=0,
    # 这里不再连 M_AXI_S2MM, axi_ic_hp 也只留 S00。

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
        foreach _cp {m_axi_mm2s_aclk m_axis_mm2s_aclk} {
            if {[get_bd_pins -quiet axi_vdma_0/$_cp] ne ""} {
                connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_vdma_0/$_cp]
            } else {
                puts "\[ACZ7015\] WARNING: axi_vdma_0/$_cp not found (skipped)"
            }
        }
    } else {
        puts "\[ACZ7015\] WARNING: axi_vdma_0 不存在，HP0 这条 Master 通路是空的"
    }

    # --- AXI4-Stream：VDMA MM2S -> pl_img_top ---------------------------------
    #       VDMA MM2S ══AXI4-Stream══► top1_0/S_AXIS
    #                                  └─► 8bit 像素流 px_* (引到顶层, 接 denose)
    #
    #  ★ 这里就是"把输入 AXI-Stream 的反压激活"的地方：
    #    pl_img_top 内部的 axis_rx_8b 会驱动 s_axis_tready，VDMA 收到 tready
    #    才会继续吐数据；下游 px_ready 拉低时整条流自动停住。
    #    如果 top1_0 不存在，VDMA 的 M_AXIS_MM2S 就没人接、tready 悬空，
    #    VDMA 会一直背压停住、帧指针不动 —— 这正是以前"数据一个都不来"的原因。
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

        # denose 之后的回写通路（VDMA S2MM）按本次改造范围【暂不接】。
        # 留一个悬空接口，Vivado 会给 unconnected 警告，不影响 MM2S 读取。
        puts "\[ACZ7015\] top1_0: VDMA MM2S -> 8bit 像素流 (tready 反压已激活)"
        puts "\[ACZ7015\]   像素流出口(接 denose): px_data/px_valid/px_eof/px_ready"
        puts "\[ACZ7015\]   (px_sof=帧首, px_eol=行尾, mode_reg/cmd_reg/cmd_pulse 备用)"
        puts "\[ACZ7015\]   VDMA S_AXIS_S2MM 本步不接(denose 之后的回写通路)"
    } else {
        puts "\[ACZ7015\] WARNING: top1_0 不存在，VDMA 的 MM2S 流口悬空"
    }

    foreach p {ACLK S00_ACLK M00_ACLK} {
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_ic_hp/$p]
    }
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins $ps7/S_AXI_HP0_ACLK]
    foreach p {S00_ARESETN M00_ARESETN} {
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

    # ★ PL 的 AXI-Lite 从机现在在 rtl/top1.v(里面的 axi_lite_rcv) —— pl_img_top 里没有。
    #   top1 加进 BD 之后, 把它的地址段固定到 0x44000000
    #   （PS 侧 pl_ctrl_test.c 里的 PL_CTRL_BASE 就是它，自动分配不会给这个地址）
    foreach _cand {top1_0} {
        if {[get_bd_cells -quiet $_cand] ne ""} {
            set _seg [get_bd_addr_segs -quiet \
                         -of_objects [get_bd_addr_spaces processing_system7_0/Data] \
                         -filter "NAME =~ \"*$_cand*\""]
            if {$_seg ne ""} {
                set_property offset 0x44000000 $_seg
                puts [format "\[ACZ7015\] %s -> offset %s" \
                          [get_property NAME $_seg] [get_property offset $_seg]]
            } else {
                error "$_cand 没有分配到地址段，检查它的 S_AXI 接口"
            }
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
