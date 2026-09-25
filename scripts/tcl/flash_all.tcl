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
#  顺序（标准 Zynq JTAG 流程）：
#      1. ps7_init            PS 的 PLL/DDR/MIO/UART
#      2. fpga -file <bit>    配 PL
#      3. dow <elf> + con     下 PS 程序并运行
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

# --------------------------- 3. 初始化 PS ------------------------------------
if {$mode eq "noinit"} {
    puts "\[flashall\] noinit: skipping ps7_init"
} else {
    if {$init ne "" && [file exists $init]} {
        source $init
        ps7_init
        ps7_post_config
        puts "\[flashall\] ps7_init done"
    } else {
        puts "\[flashall\] WARNING: no ps7_init.tcl -- DDR may not be initialised"
    }
}

# --------------------------- 4. 配置 PL --------------------------------------
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

# --------------------------- 5. 回 PS、下 ELF、运行 --------------------------
targets -set -filter {name =~ "ARM*#0"}

# 顺便确认 UART1 是通的：xil_printf 是阻塞轮询，TX 没使能的话一个字都出不来
set cr [mrd -value 0xE0001000]
puts [format "\[flashall\] UART1 CR = 0x%08X  TX_EN=%d" $cr [expr {($cr >> 4) & 1}]]

rst -processor
dow $elf
con

puts "FLASH_ALL_OK"
exit
