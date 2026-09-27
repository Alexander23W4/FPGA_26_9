# =============================================================================
#  pl_pat_test.tcl —— 判别"S2MM 到底写了哪些字节"
#
#  背景:
#      mem_dump 对比发现结果图里【每 8 字节的高 4 字节恒为 0】, 一半像素被清零。
#      两种可能, 必须分开:
#        (a) S2MM 压根没写那 4 个字节 (tkeep 只标了低 4 字节 / 写位宽只有 32bit)
#            -> 那块 DDR 会保持我们预填的值不变
#        (b) S2MM 写进去的就是 0 (接收侧 axis_rcv 把高 32 位当成了 4 个 0 像素,
#            或帧缓存里就是 0)
#            -> 那块 DDR 会变成 00
#
#  做法:
#      1. 把结果缓冲 0x20800000 前 64 字节预填成 0xEE 标记
#        (已核实: 应用里【没有任何代码写 0x20800000】, 只有 VDMA S2MM 会写它)
#      2. con 让 CPU 继续跑
#      3. 之后用串口让应用正常跑一次测试, S2MM 就会往这块 DDR 写结果
#      4. 再用 mem_dump.tcl 回读, 看那 64 字节是 0xEE 还是 0x00
#
#  用法:
#      xsct scripts/tcl/pl_pat_test.tcl [init|noinit]
#      (跑完 CPU 继续运行, 不会停下)
# =============================================================================

set mode [lindex $argv 0]
if {$mode eq ""} { set mode "noinit" }
set init "C:/Users/HUAWEI/Desktop/FPGA_26_9/csrc/fpga_26/hw/sdt/ps7_init.tcl"

set IMG_OUT  0x20800000

connect

if {[catch {targets -set -filter {name =~ "ARM*#0"}} _e]} {
    puts "!!!APU_MISSING!!! $_e"
    puts "    available targets: [targets]"
    exit 1
}
if {$mode ne "noinit"} {
    if {[file exists $init]} { source $init; ps7_init }
}

# ★ 用 stop 而不是 rst -processor: 只停核、【不复位 CPU】。这样 con 之后应用
#   能接着原来的状态继续跑(它正卡在串口等待里)。
#   rst -processor 会把 CPU 复位, 之后 con 回不到应用里 —— 实测串口一个字都没有。
stop
puts "\[pat\] CPU stopped (not reset)"

for {set i 0} {$i < 16} {incr i} {
    mwr [expr {$IMG_OUT + $i*4}] 0xEEEEEEEE
}
puts "\[pat\] marked 0x20800000\[0..63\] with 0xEEEEEEEE"
puts "\[pat\] readback:"
puts [mrd $IMG_OUT 16]

con
puts "\[pat\] CPU resumed -- now run the serial test, then re-dump with mem_dump.tcl"
puts "PAT_MARK_OK"
exit
