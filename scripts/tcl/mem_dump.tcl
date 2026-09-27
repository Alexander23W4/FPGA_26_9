# =============================================================================
#  mem_dump.tcl —— 用 JTAG 把 DDR 里两块图 dump 成文件, 用来做 PS/PL 对比
#
#  用法:
#      xsct scripts/tcl/mem_dump.tcl <out_dir> [init|noinit] [ps7_init.tcl]
#
#  为什么需要它:
#      现在 PL 是【直通】(axis_out 里算法还没接, 只是把 frame_buf 里的图送回),
#      所以 0x20800000 里 S2MM 写回的图应当和 0x10000000 里 PS 载入的输入图
#      【逐字节相同】。两块图一对比, 不一致的位置和规律就能直接指向 PL 里
#      是哪一级出的问题(收包打包 img2buf / 帧缓存 frame_buf / 回读 bufback /
#      axis_out 打包), 不需要盲猜。
#
#  会产出:
#      <out_dir>/in_img.bin   0x10000000 起 131072 字节 (PS 从 eMMC 载入的输入图)
#      <out_dir>/result.bin   0x20800000 起 131072 字节 (VDMA S2MM 写回的结果图)
#
#  ★ 读内存前必须先停核, 否则 xsct 会报
#        Cannot read memory if not stopped. ...
#    本脚本只做 rst -processor, 【绝对不用 rst -system】(见 flash_all.tcl 说明)。
#    跑完 CPU 是停住的状态, 想继续跑程序就再烧一次 ELF 或用 flash_all.tcl。
# =============================================================================

set out_dir [lindex $argv 0]
if {$out_dir eq ""} { set out_dir "." }
set mode [lindex $argv 1]
if {$mode eq ""} { set mode "noinit" }
set init [lindex $argv 2]
if {$init eq ""} {
    set init "C:/Users/HUAWEI/Desktop/FPGA_26_9/csrc/fpga_26/hw/sdt/ps7_init.tcl"
}

set BYTES   131072
set WORDS   [expr {$BYTES / 4}]     ;# mrd 的计数单位是 32bit 字

file mkdir $out_dir

connect

if {[catch {targets -set -filter {name =~ "ARM*#0"}} _e]} {
    puts "!!!APU_MISSING!!! $_e"
    puts "    available targets: [targets]"
    puts "    -> 断电重上电 (PS_POR_B) 才能恢复"
    exit 1
}

# 刚上电 / PS 还没初始化时, -init 会跑 ps7_init 把 DDR 配起来
if {$mode ne "noinit"} {
    if {[file exists $init]} {
        source $init
        ps7_init
        puts "\[dump\] ps7_init done"
    } else {
        puts "\[dump\] WARNING: ps7_init.tcl not found: $init"
    }
}

# ★ 用 stop 而不是 rst -processor:
#     · mrd 需要 CPU 停住, 否则报 "Cannot read memory if not stopped"
#     · 但 rst -processor 会复位 CPU, 会丢掉现场(缓存状态、应用进度)
#   只用 stop 只停核, 现场保留; 而 JTAG 读 DDR 是绕过 L1/L2 的,
#   所以读到的就是 DDR 里【真实】的内容 —— 这一点正是用来验证
#   "PS 写了但还在缓存里、PL 读不到" 这类问题的关键。
stop
puts "\[dump\] CPU stopped (not reset)"

mrd -bin -file [file join $out_dir in_img.bin] 0x10000000 $WORDS
puts "\[dump\] $BYTES bytes  <- 0x10000000  (PS 载入的输入图)"

mrd -bin -file [file join $out_dir result.bin] 0x20800000 $WORDS
puts "\[dump\] $BYTES bytes  <- 0x20800000  (S2MM 写回的结果图)"

puts "MEM_DUMP_OK"
exit
