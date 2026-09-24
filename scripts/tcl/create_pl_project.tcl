# =============================================================================
#  create_pl_project.tcl  ——  纯 PL（Verilog/SystemVerilog）工程模板
# =============================================================================
#  用法：
#     vivado -mode batch -source scripts/build.sh pl -tclargs <工程名> [目标目录] [顶层模块名]
#
#  例：
#     vivado -mode batch -source scripts/build.sh pl -tclargs led_demo
#     vivado -mode batch -source scripts/build.sh pl -tclargs led_demo D:/work led_flash
#
#  生成内容：
#     <目标目录>/<工程名>/
#        <工程名>.xpr
#         <工程名>.srcs/sources_1/new/<顶层>.v      （如果指定了顶层名）
#         <工程名>.srcs/constrs_1/imports/acz7015.xdc
#
#  设计特点：
#     · 器件固定 xc7z015clg485-2
#     · 自动挂载 constrs/acz7015/acz7015.xdc（板级引脚模板）
#     · 自动尝试注册 ACZ7015 板卡文件
# =============================================================================

# ----------------------------- 参数解析 -------------------------------------
set argc [llength $argv]
if {$argc < 1} {
    puts "用法: vivado -mode batch -source create_pl_project.tcl -tclargs <工程名> \[目标目录\] \[顶层模块名\]"
    puts "例  : vivado -mode batch -source create_pl_project.tcl -tclargs led_demo"
    exit 1
}

set proj_name  [lindex $argv 0]
set proj_dir   [expr {$argc >= 2 ? [lindex $argv 1] : "C:/Users/HUAWEI/Desktop/FPGA_26_9/build"}]
set top_name   [expr {$argc >= 3 ? [lindex $argv 2] : ""}]

# 脚本所在目录 -> 仓库根
set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set xdc_file   [file normalize [file join $repo_root constrs acz7015 acz7015.xdc]]

set part_name  "xc7z015clg485-2"

puts "=============================================="
puts " ACZ7015 纯 PL 工程创建"
puts "   工程名   : $proj_name"
puts "   目标目录 : $proj_dir"
puts "   顶层模块 : [expr {$top_name eq "" ? "(未指定)" : $top_name}]"
puts "   器件     : $part_name"
puts "   约束文件 : $xdc_file"
puts "=============================================="

# ----------------------------- 注册板卡 -------------------------------------
set board_repo [file normalize [file join $repo_root board acz7015 board_files]]
if {[file isdirectory $board_repo]} {
    if {[catch {set_param board.repoPaths [list $board_repo]} e]} {
        puts "\[ACZ7015\] 板卡注册跳过: $e"
    }
}

# ----------------------------- 创建工程 -------------------------------------
file mkdir $proj_dir
create_project $proj_name [file join $proj_dir $proj_name] -part $part_name -force

set_property target_language Verilog [current_project]
set_property default_lib      work     [current_project]

# ----------------------------- 添加约束 -------------------------------------
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "\[ACZ7015\] 已添加约束: $xdc_file"
    puts "\[ACZ7015\] ⚠ 记得把 XDC 里用不到的段落注释掉，否则 get_ports 找不到端口会报错"
} else {
    puts "\[ACZ7015\] ⚠ 未找到 $xdc_file，请手动添加约束"
}

# ----------------------------- 生成顶层模板 ---------------------------------
if {$top_name ne ""} {
    set src_dir [file join $proj_dir $proj_name "${proj_name}.srcs" sources_1 new]
    file mkdir $src_dir
    set vfile [file join $src_dir "${top_name}.v"]
    set fp [open $vfile w]
    puts $fp "// ============================================================"
    puts $fp "//  $top_name  ——  ACZ7015 顶层模板"
    puts $fp "//  器件: $part_name"
    puts $fp "//"
    puts $fp "//  时钟: clk50M (L5, 50 MHz)"
    puts $fp "//  复位: reset_n (R4, 低有效)"
    puts $fp "//  8位LED: led[7:0]  (AB14 AA14 AA15 AA12 R17 T17 U19 V19)"
    puts $fp "//  4位按键: key_in0..3 (AB12 V11 W11 AA11)"
    puts $fp "//"
    puts $fp "//  约束见 constrs/acz7015/acz7015.xdc，端口名需与之一致"
    puts $fp "// ============================================================"
    puts $fp "module $top_name ("
    puts $fp "    input  wire clk50M,        // 50 MHz 系统时钟"
    puts $fp "    input  wire reset_n,       // 低有效复位"
    puts $fp "    output wire \[7:0\] led       // 8 位 LED"
    puts $fp ");"
    puts $fp ""
    puts $fp "    // ---------------- 1 Hz 心跳，验证时钟与复位 ----------------"
    puts $fp "    reg \[25:0\] cnt;"
    puts $fp "    always @(posedge clk50M or negedge reset_n) begin"
    puts $fp "        if (!reset_n)      cnt <= 26'd0;"
    puts $fp "        else if (cnt == 26'd49_999_999) cnt <= 26'd0;"
    puts $fp "        else               cnt <= cnt + 1'b1;"
    puts $fp "    end"
    puts $fp ""
    puts $fp "    assign led = {8{cnt\[25\]}};   // 全亮/全灭 交替，约 0.75 Hz"
    puts $fp ""
    puts $fp "endmodule"
    close $fp
    add_files -fileset sources_1 -norecurse $vfile
    set_property top $top_name [current_fileset]
    puts "\[ACZ7015\] 已生成顶层模板: $vfile"
}

update_compile_order -fileset sources_1

puts "=============================================="
puts " 工程创建完成"
puts "   $proj_dir/$proj_name/$proj_name.xpr"
puts "=============================================="
puts "DONE"
