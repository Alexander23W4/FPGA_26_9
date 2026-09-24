# =============================================================================
#  export_project.tcl —— 把 GUI 里改过的工程导回 Tcl
# =============================================================================
#  由 scripts/build.sh export 调用。
#  参数: <工程名> <工程目录> <输出目录>
#
#  用途：
#      build/vivado/ 下的工程是不入库的（.gitignore 挡住了）。
#      你在 GUI 里做了改动（加 IP、改 BD、加约束）之后，
#      跑一遍本脚本，把工程状态导出成 Tcl，提交那些 Tcl 即可。
#      下次别人 clone 下来就能用这些 Tcl 完整重建。
# =============================================================================

set name  [lindex $argv 0]
set pdir  [lindex $argv 1]
set odir  [lindex $argv 2]

if {$name eq "" || $pdir eq "" || $odir eq ""} {
    puts "!!!ARGS!!! export_project.tcl 需要: <工程名> <工程目录> <输出目录>"
    exit 1
}

set xpr [file join $pdir $name "${name}.xpr"]
if {![file exists $xpr]} {
    puts "!!!NOXPR!!! 找不到工程: $xpr"
    exit 1
}

file mkdir $odir
open_project $xpr

# --------------------------- 1. 工程整体 Tcl --------------------------------
set proj_tcl [file join $odir "${name}_project.tcl"]
if {[catch {
    write_project_tcl -force -paths_relative_to $odir $proj_tcl
} e]} {
    puts "\[export\] write_project_tcl 失败: $e"
} else {
    puts "PROJECT_TCL=$proj_tcl"
}

# --------------------------- 2. 每个 BD 单独导出 ----------------------------
foreach bd [get_files -quiet *.bd] {
    set bdname [file rootname [file tail $bd]]
    set bd_tcl [file join $odir "${bdname}.tcl"]
    if {[catch {
        open_bd_design $bd
        write_bd_tcl -force -no_ip_version $bd_tcl
        puts "BD_TCL=$bd_tcl"
    } e]} {
        puts "\[export\] BD $bdname 导出失败: $e"
    }
}

# --------------------------- 3. 约束也复制一份 ------------------------------
# 约束源文件本来就在 constrs/ 下（入库的），这里只做提示
puts "\[export\] 提示：约束文件请直接改 constrs/ 下的源文件，本脚本不复制"

close_project
puts "EXPORT_OK"
