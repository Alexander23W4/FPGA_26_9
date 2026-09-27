# =============================================================================
#  flash_all.tcl —— 通过 JTAG 把【PL 比特流 + PS 程序】一起下进去并运行
# =============================================================================
#  用法：
#      xsct scripts/tcl/flash_all.tcl <bit> <elf> <ps7_init.tcl> [init|noinit]
#
#  和 flash_app.tcl 的区别：
#      flash_app.tcl 只下 ELF，【不配 PL】。
#      但这个设计里有 PL 外设（AXI VDMA 等），PL 不配置的话：
#        - PS 去读 PL 的寄存器会 AXI DECERR，可能直接把 PS 挂住
#        - VDMA 根本不存在
#      所以只要设计里有 PL 外设，就必须用这个脚本。
#
#  顺序（标准 Zynq JTAG 流程 —— 顺序本身很关键，别改）：
#      1. rst -processor      先停核（PS 上的程序可能正在对 PL 发 AXI 事务）
#      2. ps7_init            PS 的 PLL/DDR/MIO/UART
#      3. fpga -file <bit>    配 PL
#      4. ps7_post_config     ★ 必须在 fpga -file 【之后】
#                             它按当前已配置的 PL 设置 PS-PL 接口(含 S_AXI_HP0)
#      5. dow <elf> + con     下 PS 程序并运行
#
#  ★★ 绝对不要用 `rst -system` ★★
#      实测会对 Zynq 造成 DAP (APB AP transaction error, DAP status 0x30000021)，
#      APU 从 JTAG 链里消失，只能断电恢复。要复位 CPU 只用 `rst -processor`。
# =============================================================================

set bit  [lindex $argv 0]
set elf  [lindex $argv 1]
set init [lindex $argv 2]
set mode [lindex $argv 3]
if {$mode eq ""} { set mode "init" }

# ★ 曾经有一个 "oldorder" 模式: 把 ps7_post_config 放在 fpga -file 之前、
#   并且配 PL 前不停核。实测它【稳定打死 DAP】:
#       不停核 -> ps7_init 通过 APB 访问 PS 寄存器失败 ->
#       Cannot read memory if not stopped. Context ARM Cortex-A9 MPCore #0
#       state: APB AP transaction error, DAP status 0xF0000021
#   之后整条 JTAG 链只剩一个坏的 DAP(0x30000021), 只能断电恢复。
#   所以那个模式已经删除, 现在只有一条正确的顺序。

if {$bit eq "" || $elf eq ""} {
    puts "!!!ARGS!!! flash_all.tcl requires: <bit> <elf> \[ps7_init.tcl\] \[init|noinit\]"
    exit 1
}
if {![file exists $bit]} { puts "!!!NOBIT!!! not found: $bit" ; exit 1 }
if {![file exists $elf]} { puts "!!!NOELF!!! not found: $elf" ; exit 1 }

puts "\[flashall\] mode     : $mode"
puts "\[flashall\] bitstream: $bit"
puts "\[flashall\] elf      : $elf"
puts "\[flashall\] ps7_init : $init"

# --------------------------- 1. 连接 ----------------------------------------
connect

# --------------------------- 2. 检查 APU 在不在 ------------------------------
if {[catch {targets -set -filter {name =~ "ARM*#0"}} _e]} {
    puts "!!!APU_MISSING!!!"
    puts "    Cortex-A9 debug target is NOT in the JTAG chain."
    puts "    available targets: [targets]"
    puts ""
    puts "    Two known causes, check IN THIS ORDER:"
    puts "    1) A STALE hw_server is holding a dead scan chain. Very common and"
    puts "       it looks exactly like a dead board ('targets' prints an EMPTY"
    puts "       chain even though the board is powered on)."
    puts "       FIX:  taskkill /F /IM hw_server.exe"
    puts "             taskkill /F /IM cs_server.exe"
    puts "    2) A previous 'rst -system' left the PS half-initialised."
    puts "       FIX:  power-cycle the board (PS_POR_B)."
    exit 1
}
puts "\[flashall\] APU found: [targets]"

# --------------------------- 3. 先停核（必须在配 PL 之前）--------------------
#  ★★ 这一步原来是缺的, 而且很关键。PS 上的程序如果正在跑, 很可能正在对 PL
#     发 AXI 事务(VDMA 的读写两拍都在跑)。这时直接重配 PL, 会在 PS 的 AXI/HP
#     通路上留下一个永远不返回的事务, 之后 VDMA 就变成
#     "CR 里有 RS、SR 没有错误位、但一个 beat 都不吐"。
#     先 rst -processor 把核停住, 再动 PL。
#     注意: 只用 rst -processor, 【绝对不要用 rst -system】(见文件头说明)。
targets -set -filter {name =~ "ARM*#0"}
rst -processor
puts "\[flashall\] CPU halted (before programming PL)"

# --------------------------- 4. 初始化 PS ------------------------------------
# 先把 init 文件 source 进来: 它同时定义 ps7_init 和 ps7_post_config,
# 而 ps7_post_config 要留到 PL 配好之后才调用。
set have_cfg 0
if {$init ne "" && [file exists $init]} {
    source $init
    set have_cfg 1
}
if {$mode eq "noinit"} {
    puts "\[flashall\] noinit: skipping ps7_init"
} elseif {$have_cfg} {
    ps7_init
    puts "\[flashall\] ps7_init done"
} else {
    puts "\[flashall\] WARNING: no ps7_init.tcl -- DDR may not be initialised"
}

# --------------------------- 5. 配置 PL --------------------------------------
# 这一步是 flash_app.tcl 缺的。跳过它 -> PL 里没有 VDMA，PS 读它的寄存器
# 会 AXI DECERR（可能直接异常挂住）。
puts "\[flashall\] programming PL ..."
if {[catch {
    targets -set -filter {name =~ "*xc7z*"}
    fpga -file $bit
} _e]} {
    puts "!!!PL_PROGRAM_FAILED!!! $_e"
    puts "    targets: [targets]"
    exit 1
}
puts "\[flashall\] PL programmed"

# --------------------------- 6. 回 PS + ps7_post_config ----------------------
#  ★★ ps7_post_config 必须在 fpga -file 【之后】调用。
#     它负责按【当前已经配好的 PL】来设置 PS-PL 接口(包括 S_AXI_HP0 通路的
#     PS 侧配置)。放在 fpga -file 之前调用, 配的就是上一版/空 PL,
#     HP0 通路就可能一直不返回事务。原来的代码就是放错了位置。
targets -set -filter {name =~ "ARM*#0"}
if {$have_cfg} {
    ps7_post_config
    puts "\[flashall\] ps7_post_config done (AFTER PL programming)"
}

# 顺便确认 UART1 是通的：xil_printf 是阻塞轮询，TX 没使能的话一个字都出不来
set cr [mrd -value 0xE0001000]
puts [format "\[flashall\] UART1 CR = 0x%08X  TX_EN=%d" $cr [expr {($cr >> 4) & 1}]]

rst -processor
dow $elf
con

puts "FLASH_ALL_OK"
exit
