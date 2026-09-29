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
                CONFIG.c_include_s2mm            {1} \
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

    # PL 顶层 rtl/pl_img_top.v（单文件单模块：收 AXI-Stream + 8bit 像素流 + AXI-Lite）。
    #
    # ★ 本次改造：旧的一整条 16bit 通路已作废删除
    #   （top1 / axis_rcv / axis_out / img2buf / bufback / frame_buf / axi_lite_rcv），
    #   现在只保留"接收 VDMA 的 AXI-Stream、并把它暴露成 8bit 像素流"这一段。
    #   画面从 256x256x16bit 改成 256x256x8bit，一行 512 -> 256 字节。
    #   （原来单独的 axis_rx_8b.v 已内联进 pl_img_top.v，不再有子模块。）
    set _pl_rtl [list \
        [file normalize [file join $repo_root rtl pl_img_top.v]]]
    set _pl_ok 1
    foreach _f $_pl_rtl {
        if {![file exists $_f]} {
            puts "\[ACZ7015\] WARNING: 缺少 [file tail $_f]"
            set _pl_ok 0
        }
    }
    # 只有 -hp（有 axi_vdma_0）时才接 PL 前端，否则它的 AXI-Stream 从口没人接
    set _pl_en [expr {$_pl_ok && $want_hp}]
    # ★ pl_img_top 只做 "AXI-Stream -> 8bit 像素流", 没有 AXI-Lite 从口,
    #   所以它不占 axi_interconnect_0 的 MI 口, 也不需要分配地址段。
    #   （PS 的控制/状态寄存器在 rtl/top1.v 的 axi_lite_rcv 里, 等 top1 加进 BD 再分配）
    set nmi   $nm

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
    #  PL 顶层：rtl/pl_img_top.v
    #
    #      PS(M_AXI_GP0) -> axi_interconnect_0/S00_AXI
    #                          -> M04_AXI -> pl_img_top_0/S_AXI
    #
    #  pl_img_top 里面自带 AXI-Lite 从机（模式/控制寄存器 + 调试计数），
    #  所以 BD 里【只加这一个】模块。
    #
    #  它看到的 slave 地址是【偏移】后的（interconnect 把基地址剥掉了）：
    #      awaddr = 0x000 / 0x010 / 0x020   (MODE / CMD / DATA)
    #
    #  pl_img_top 的 rst 是【高有效】，而 BD 只有低有效的 peripheral_aresetn，
    #  所以中间串一个反相器。
    # =========================================================================
    if {$_pl_en} {
        add_files -norecurse $_pl_rtl
        create_bd_cell -type module -reference pl_img_top pl_img_top_0

        # ★ pl_img_top 没有 AXI-Lite 从口, 所以不接 axi_interconnect_0,
        #   也不需要分配地址段。PS 的控制/状态寄存器在 rtl/top1.v 里。

        # 时钟
        connect_bd_net [get_bd_pins $ps7/FCLK_CLK0] [get_bd_pins pl_img_top_0/clk]

        # 复位反相： peripheral_aresetn(低有效) -> pl_img_top_0/rst(高有效)
        create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 pl_rst_inv
        set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells pl_rst_inv]
        connect_bd_net [get_bd_pins rst_ps7_50M/peripheral_aresetn] [get_bd_pins pl_rst_inv/Op1]
        connect_bd_net [get_bd_pins pl_rst_inv/Res]                 [get_bd_pins pl_img_top_0/rst]

        puts "\[ACZ7015\] pl_img_top_0: 只做 AXI-Stream -> 8bit 像素流 (无 AXI-Lite, 不占 MI 口)"
    } else {
        puts "\[ACZ7015\] WARNING: rtl/pl_img_top.v 缺失，BD 里没有 PL 逻辑"
    }

    # =========================================================================
    #  HDMI 控制器: 输出 -> 板上 HDMI_2 (J7) 的原生 TMDS 引脚
    #
    #  引脚约束已经在 constrs/acz7015/acz7015.xdc 里写好了(端口名一致):
    #      tmds_data_p[2]  K7      tmds_data_p[1]  M8
    #      tmds_data_p[0]  N6      tmds_clk_p      T2      (IOSTANDARD TMDS_33)
    #  差分对 N 端由 OBUFDS 自动配对, XDC 里不用单列。
    #
    #  ★ 输入(pclk / pclk_x5 / rst / vid_r / vid_g / vid_b / vid_hs / vid_vs /
    #    vid_de)按你的要求【留空】, 你自己在 BD 里接。
    # =========================================================================
    set _hdmi_rtl [file normalize [file join $repo_root rtl hdmi_tx.v]]
    if {[file exists $_hdmi_rtl]} {
        add_files -norecurse [list $_hdmi_rtl]
        create_bd_cell -type module -reference hdmi_tx hdmi_tx_0

        # TMDS 输出引到 BD 顶层端口(名字和 XDC 里的约束一致)
        create_bd_port -dir O -from 2 -to 0 tmds_data_p
        create_bd_port -dir O                   tmds_clk_p
        connect_bd_net [get_bd_pins hdmi_tx_0/tmds_data_p] [get_bd_ports tmds_data_p]
        connect_bd_net [get_bd_pins hdmi_tx_0/tmds_clk_p]  [get_bd_ports tmds_clk_p]

        puts "\[ACZ7015\] hdmi_tx_0: TMDS 输出 -> tmds_data_p[2:0] / tmds_clk_p (板上 HDMI_2 J7)"
        puts "\[ACZ7015\]          输入 pclk/pclk_x5/rst/vid_* 留空, 待接"
    } else {
        puts "\[ACZ7015\] WARNING: rtl/hdmi_tx.v 缺失，BD 里没有 HDMI 控制器"
    }

    # =========================================================================
    #  板载 50 MHz 有源晶振 (clk50M, 引脚 L5) 引入 BD
    #
    #  constrs/acz7015/acz7015.xdc 第 1 节已经写好:
    #      create_clock -period 20.000 -name sys_clk [get_ports clk50M]
    #      set_property PACKAGE_PIN L5 [get_ports clk50M]
    #  这里 BD 顶层端口用【同名】clk50M, 上面的约束自动生效, 不需要改 XDC。
    #
    #  ★ 板子上【只有】这一颗时钟晶振。pclk_x5(126MHz) / pclk(25.2MHz) 板上没有,
    #    必须由这颗 50MHz 经 clk_wiz(MMCM) 产生:
    #         CLKFBOUT_MULT = 63, DIVCLK_DIVIDE = 5   -> VCO = 630 MHz
    #         CLKOUT0_DIVIDE = 25 -> pclk    = 25.2 MHz
    #         CLKOUT1_DIVIDE =  5 -> pclk_x5 = 126 MHz   (严格 5 倍)
    # =========================================================================
    if {[get_bd_ports -quiet clk50M] eq ""} {
        create_bd_port -dir I clk50M
        puts "\[ACZ7015\] clk50M (L5, 50MHz) 已引到 BD 顶层"
    }

    # ---- clk_wiz: 50MHz -> pclk 25.2MHz + pclk_x5 126MHz (严格 5 倍) ----
    #      VCO = 50 * 63 / 5 = 630 MHz
    #      pclk    = 630 / 25 = 25.2 MHz
    #      pclk_x5 = 630 /  5 = 126  MHz      126 / 25.2 = 5.000 ✓
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

    if {[get_bd_cells -quiet top1_0] ne ""} {
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins top1_0/pclk]
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins top1_0/pclk_x5]
        puts "\[ACZ7015\] clk_wiz_0: 50MHz -> pclk 25.2MHz / pclk_x5 126MHz -> top1_0"
        puts "\[ACZ7015\]   VCO=630MHz, M=63 D=5 O0=25 O1=5, 126/25.2 = 5.000"
        puts "\[ACZ7015\]   clk_wiz_0/locked 待接(复位要用它)"
    } else {
        puts "\[ACZ7015\] clk_wiz_0 已建好(50MHz -> 25.2/126MHz); top1_0 还没加进 BD, 待接"
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

    # --- AXI4-Stream：VDMA MM2S -> pl_img_top ---------------------------------
    #       VDMA MM2S ══AXI4-Stream══► pl_img_top_0/S_AXIS
    #                                  └─► 8bit 像素流 px_* (引到顶层, 接 denose)
    #
    #  ★ 这里就是"把输入 AXI-Stream 的反压激活"的地方：
    #    pl_img_top 内部的 axis_rx_8b 会驱动 s_axis_tready，VDMA 收到 tready
    #    才会继续吐数据；下游 px_ready 拉低时整条流自动停住。
    #    如果 pl_img_top_0 不存在，VDMA 的 M_AXIS_MM2S 就没人接、tready 悬空，
    #    VDMA 会一直背压停住、帧指针不动 —— 这正是以前"数据一个都不来"的原因。
    if {[get_bd_cells -quiet pl_img_top_0] ne ""} {

        if {[catch {
            connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] \
                                [get_bd_intf_pins pl_img_top_0/S_AXIS]
        } _e]} {
            puts "\[ACZ7015\] pl_img_top_0/S_AXIS 没被推断出来，逐根连"
            foreach {vp rp} {
                M_AXIS_MM2S_TDATA  s_axis_tdata
                M_AXIS_MM2S_TVALID s_axis_tvalid
                M_AXIS_MM2S_TREADY s_axis_tready
                M_AXIS_MM2S_TLAST  s_axis_tlast
                M_AXIS_MM2S_TKEEP  s_axis_tkeep
                M_AXIS_MM2S_TUSER  s_axis_tuser
            } {
                connect_bd_net [get_bd_pins axi_vdma_0/$vp] [get_bd_pins pl_img_top_0/$rp]
            }
        }

        # denose 之后的回写通路（VDMA S2MM）按本次改造范围【暂不接】。
        # 留一个悬空接口，Vivado 会给 unconnected 警告，不影响 MM2S 读取。
        puts "\[ACZ7015\] pl_img_top_0: VDMA MM2S -> 8bit 像素流 (tready 反压已激活)"
        puts "\[ACZ7015\]   像素流出口(接 denose): px_data/px_valid/px_eof/px_ready"
        puts "\[ACZ7015\]   (px_sof=帧首, px_eol=行尾, mode_reg/cmd_reg/cmd_pulse 备用)"
        puts "\[ACZ7015\]   VDMA S_AXIS_S2MM 本步不接(denose 之后的回写通路)"
    } else {
        puts "\[ACZ7015\] WARNING: pl_img_top_0 不存在，VDMA 的 MM2S 流口悬空"
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
