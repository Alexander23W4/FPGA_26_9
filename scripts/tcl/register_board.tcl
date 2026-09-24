# =============================================================================
#  注册 ACZ7015 板卡文件到当前 Vivado 会话
# -----------------------------------------------------------------------------
#  用法（GUI 的 Tcl Console，或 batch）：
#      source <本文件>
#  之后新建工程时选板列表里就能看到 "Xiaomeige ACZ7015 (Zynq-7015)"
#
#  持久化（每次启动 Vivado 都生效）：
#      见本文件末尾注释
# =============================================================================

# 本脚本位于 <repo>/scripts/tcl/ ，板卡库在 <repo>/board/acz7015/board_files/
set _acz_script_dir  [file normalize [file dirname [info script]]]
set _acz_repo_root   [file normalize [file join $_acz_script_dir .. ..]]
set _acz_board_repo  [file normalize [file join $_acz_repo_root board acz7015 board_files]]

if {![file isdirectory $_acz_board_repo]} {
    error "Board repo directory not found: $_acz_board_repo"
}

# 把自定义板卡库加到 repoPaths 的最前面（保留原有的）
set _acz_paths [list $_acz_board_repo]
if {[catch {set_param board.repoPaths} _acz_old] == 0 && $_acz_old ne ""} {
    foreach _p $_acz_old {
        if {$_p ne "" && [lsearch $_acz_paths $_p] < 0} { lappend _acz_paths $_p }
    }
}
set_param board.repoPaths $_acz_paths

puts "\[ACZ7015\] Board repo registered:"
foreach _p $_acz_paths { puts "           $_p" }

set _acz_found [get_board_parts -quiet *acz7015*]
if {$_acz_found eq ""} {
    puts "\[ACZ7015\] WARNING: acz7015 board not found. Check $_acz_board_repo"
} else {
    puts "\[ACZ7015\] Board found: $_acz_found"
}

# -----------------------------------------------------------------------------
# 让注册持久化的两种办法（任选其一）：
#
#  A) 写进 Vivado 初始化脚本
#     Vivado 启动时会自动 source   <用户目录>\Xilinx\Vivado\2023.2\Vivado_init.tcl
#     把下面这行追加进去即可：
#         set_param board.repoPaths [list "C:/Users/HUAWEI/Desktop/FPGA_26_9/board/acz7015/board_files"]
#
#  B) 把板卡目录复制到 Vivado 安装目录的板卡库里
#         E:\Xilinx\Vivado\2023.2\data\xhub\boards\XilinxBoardStore\boards\
#     （需要管理员权限，升级 Vivado 会丢）
#
#  推荐 A。
# -----------------------------------------------------------------------------
