# =============================================================================
#  connect_ila.tcl -- 在【现有工程】上把调试 ILA 补接好 (不重建工程, 不动 RTL)
#
#  为什么需要它:
#    create_zynq_project.tcl 里的 ILA 连线只在【建工程时】执行一次;
#    如果那次 top1_0/debug_probe 还不存在, 它就走 else 分支跳过,
#    之后任何重建 (build_zynq.tcl) 都不会再补 => ILA 有核无探针 => 被优化掉
#    => 板上 ILA cores found: 0
#
#  这个脚本做两件事:
#    ① 把 u_ila_hdmi/probe0 接到 top1_0/debug_probe
#       (看 hdl_out 的 state/buf_idx/counter、帧缓存写地址、HDMI 读状态)
#    ② 新建 system_ila, 以 AXI 监控模式挂在 top1_0/s_axi 上
#       ★ 这个才是回答"0x10 有没有到 PL、有没有被应答"的东西:
#         awaddr / awvalid / awready / wdata / wvalid / wready / bvalid / rdata
#
#  用法:
#    vivado -mode batch -notrace -nojournal -nolog \
#        -source scripts/tcl/connect_ila.tcl -tclargs <xpr>
#
#  修改前会先验证所有必需的引脚/接口。BD 验证失败时不会保存。
# =============================================================================

if {[llength $argv] < 1} { puts "\[ila\] 用法: connect_ila.tcl <xpr>"; exit 1 }
set xpr [lindex $argv 0]
if {![file exists $xpr]} { puts "\[ila\] xpr 不存在: $xpr"; exit 1 }

proc ila_require_one {objects label} {
    if {[llength $objects] != 1} {
        error "$label: expected exactly one object, found [llength $objects]"
    }
    return [lindex $objects 0]
}

proc ila_connect_pin_to_source_net {source_path sink_path} {
    set source [ila_require_one [get_bd_pins -quiet $source_path] $source_path]
    set sink [ila_require_one [get_bd_pins -quiet $sink_path] $sink_path]
    set source_nets [get_bd_nets -quiet -of_objects $source]
    set sink_nets [get_bd_nets -quiet -of_objects $sink]
    if {[llength $source_nets] != 1} {
        error "$source_path is not connected to exactly one net"
    }
    if {$sink_nets eq $source_nets} {
        return
    }
    if {[llength $sink_nets] != 0} {
        error "$sink_path is already connected to a different net"
    }
    connect_bd_net -net [lindex $source_nets 0] $sink
}

set project_open 0
if {[catch {
    open_project $xpr
    set project_open 1

    set bd [get_files -quiet system.bd]
    if {$bd eq ""} { set bd [get_files -quiet *.bd] }
    set bd [ila_require_one $bd "Block Design"]
    puts "\[ila\] BD = $bd"
    open_bd_design $bd

    set top_cell [ila_require_one [get_bd_cells -quiet top1_0] top1_0]
    set clk_pin [ila_require_one [get_bd_pins -quiet clk_wiz_0/clk_out1] clk_wiz_0/clk_out1]
    set reset_pin [ila_require_one [get_bd_pins -quiet rst_ps7_50M/peripheral_aresetn] rst_ps7_50M/peripheral_aresetn]
    set debug_pin [ila_require_one [get_bd_pins -quiet top1_0/debug_probe] top1_0/debug_probe]
    set axi_pin [ila_require_one [get_bd_intf_pins -quiet top1_0/S_AXI] top1_0/S_AXI]

    # ---------------------------------------------------------------- ① debug_probe ILA
    puts "\[ila\] --- 1) HDMI/debug_probe ILA ---"
    set hdmi_ila [get_bd_cells -quiet u_ila_hdmi]
    if {$hdmi_ila eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 u_ila_hdmi
        set hdmi_ila [ila_require_one [get_bd_cells -quiet u_ila_hdmi] u_ila_hdmi]
        set_property -dict [list \
            CONFIG.C_DATA_DEPTH    {2048} \
            CONFIG.C_NUM_OF_PROBES {1} \
            CONFIG.C_PROBE0_WIDTH  {128} \
        ] $hdmi_ila
    }
    ila_connect_pin_to_source_net clk_wiz_0/clk_out1 u_ila_hdmi/clk
    ila_connect_pin_to_source_net top1_0/debug_probe u_ila_hdmi/probe0
    puts "\[ila\]    HDMI probe and clock connected"

    # ---------------------------------------------------------------- ② AXI-Lite interface ILA
    puts "\[ila\] --- 2) AXI-Lite monitor on top1_0/S_AXI ---"
    set axi_ila [get_bd_cells -quiet u_ila_saxi]
    if {$axi_ila eq ""} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 u_ila_saxi
        set axi_ila [ila_require_one [get_bd_cells -quiet u_ila_saxi] u_ila_saxi]
    }
    set_property -dict [list \
        CONFIG.C_MON_TYPE          {INTERFACE} \
        CONFIG.C_NUM_MONITOR_SLOTS {1} \
        CONFIG.C_SLOT_0_INTF_TYPE  {xilinx.com:interface:aximm_rtl:1.0} \
        CONFIG.C_DATA_DEPTH        {4096} \
        CONFIG.C_ADV_TRIGGER       {false} \
    ] $axi_ila
    set axi_monitor [ila_require_one \
        [get_bd_intf_pins -quiet u_ila_saxi/SLOT_0_AXI] u_ila_saxi/SLOT_0_AXI]
    set axi_source_nets [get_bd_intf_nets -quiet -of_objects $axi_pin]
    set axi_monitor_nets [get_bd_intf_nets -quiet -of_objects $axi_monitor]
    if {[llength $axi_source_nets] != 1} {
        error "top1_0/S_AXI is not connected to exactly one AXI interface net"
    }
    if {$axi_monitor_nets ne $axi_source_nets} {
        if {[llength $axi_monitor_nets] != 0} {
            error "u_ila_saxi/SLOT_0_AXI is already connected to a different AXI net"
        }
        connect_bd_intf_net $axi_pin $axi_monitor
    }
    ila_connect_pin_to_source_net clk_wiz_0/clk_out1 u_ila_saxi/clk
    if {[llength [get_bd_pins -quiet u_ila_saxi/resetn]] == 1} {
        ila_connect_pin_to_source_net rst_ps7_50M/peripheral_aresetn u_ila_saxi/resetn
    }
    puts "\[ila\]    AXI monitor connected to top1_0/S_AXI"

    # Do not persist a partial/invalid instrumentation edit.
    validate_bd_design
    save_bd_design
    generate_target all [get_files $bd]
    close_project
    set project_open 0
} error]} {
    puts stderr "\[ila\] ERROR: $error"
    if {$project_open} {
        catch {close_project}
    }
    exit 1
}

puts "\[ila\] DONE -- now rebuild with ./scripts/build.sh zynq -n fpga_26 -H"
