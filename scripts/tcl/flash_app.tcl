# =============================================================================
#  flash_app.tcl —— 通过 JTAG 把 ELF 下载到 DDR 直接运行（不写 flash）
# =============================================================================
#  用法：
#      xsct scripts/tcl/flash_app.tcl <elf> <ps7_init.tcl> [init|noinit]
#
#  模式：
#      init  （默认，刚上电后第一次用）
#            跑 ps7_init 初始化 PS（PLL/DDR/MIO/UART）-> 复位 CPU -> 下载 -> 运行
#
#      noinit（板子已经初始化过、只是改了代码重烧）
#            跳过 ps7_init，直接复位 CPU -> 下载 -> 运行
#
#  ★★ 绝对不要用 `rst -system` ★★
#      实测：对 Zynq 执行 rst -system 之后，PS 会停在半初始化状态，
#      APU（Cortex-A9 调试口）直接从 JTAG 链里消失，报
#          DAP (APB AP transaction error, DAP status 0x30000021)
#      之后所有烧录都 targets 不到 ARM 核 —— 表现就是"烧录没反应、串口没输出"。
#      恢复办法只有给板子断电重上电（或按复位键 PS_POR_B）。
#      要复位 CPU 只用 `rst -processor`，它不动 PS 的外设和时钟。
#
#  ★ 只改 DDR 里的内容，不动 QSPI flash，随时可以重新下。
# =============================================================================

set elf  [lindex $argv 0]
set init [lindex $argv 1]
set mode [lindex $argv 2]
if {$mode eq ""} { set mode "init" }

if {$elf eq ""} {
    puts "!!!ARGS!!! flash_app.tcl requires: <elf> \[ps7_init.tcl\] \[init|noinit\]"
    exit 1
}
if {![file exists $elf]} {
    puts "!!!NOELF!!! not found: $elf"
    exit 1
}

puts "\[flash\] mode     : $mode"
puts "\[flash\] elf      : $elf"
puts "\[flash\] ps7_init : $init"

# --------------------------- 1. 连接 ----------------------------------------
connect

# --------------------------- 2. 检查 APU 在不在 ------------------------------
if {[catch {targets -set -filter {name =~ "ARM*#0"}} _e]} {
    puts "!!!APU_MISSING!!!"
    puts "    Cortex-A9 debug target is NOT in the JTAG chain."
    puts "    available targets: [targets]"
    puts ""
    puts "    The PS debug port is not responding. Most likely a previous"
    puts "    'rst -system' left the PS half-initialised."
    puts ""
    puts "    FIX: power-cycle the board, or press the reset button (PS_POR_B)."
    puts "         Then re-run this script."
    exit 1
}
puts "\[flash\] APU found: [targets]"

# --------------------------- 3. 可选：初始化 PS -------------------------------
if {$mode eq "noinit"} {
    puts "\[flash\] noinit mode: skipping ps7_init (PS assumed already initialised)"
} else {
    if {$init ne "" && [file exists $init]} {
        source $init
        ps7_init
        ps7_post_config
        puts "\[flash\] ps7_init done"
    } else {
        puts "\[flash\] WARNING: no ps7_init.tcl -- DDR may not be initialised"
    }
}

# --------------------------- 4. 回读 UART1 状态 -------------------------------
# xil_printf -> outbyte -> XUartPs_SendByte 是【阻塞轮询】：
#     while (XUartPs_IsTransmitFull(ba)) { }      <- 等 TX FIFO 有空位
# 如果 TX 没使能（CR 的 bit4 = 0），FIFO 永远不排空，第一条 xil_printf
# 就死循环 —— 现象是"串口一个字都没有"。
set cr      [mrd -value 0xE0001000]
set baudgen [mrd -value 0xE0001018]
set bauddiv [mrd -value 0xE0001034]
puts [format "\[flash\] UART1 CR      = 0x%08X   TX_EN=%d RX_EN=%d" \
          $cr [expr {($cr >> 4) & 1}] [expr {($cr >> 2) & 1}]]
puts [format "\[flash\] UART1 BAUDGEN = 0x%08X (%d)" $baudgen $baudgen]
puts [format "\[flash\] UART1 BAUDDIV = 0x%08X (%d)" $bauddiv $bauddiv]

if {[expr {($cr >> 4) & 1}] == 0} {
    puts "!!!UART_TX_DISABLED!!!"
    puts "    UART1 TX is not enabled, so xil_printf will hang on its first call"
    puts "    and the serial port stays silent."
    puts "    -> re-run in 'init' mode so ps7_init configures UART1."
    exit 1
}
if {$baudgen != 124 || $bauddiv != 6} {
    puts "!!!UART_BAUD_WEIRD!!! expected BAUDGEN=124 BAUDDIV=6 (=115200 baud),"
    puts "                      something re-initialised UART1 with other values."
}

# --------------------------- 5. 下载并运行 -----------------------------------
targets -set -filter {name =~ "ARM*#0"}
rst -processor
dow $elf
con

puts "FLASH_OK"
exit
