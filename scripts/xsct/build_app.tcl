# =============================================================================
#  build_app.tcl —— PS 端应用构建（由 xsct 执行，不是 vivado）
# =============================================================================
#  由 scripts/build.sh app 调用。
#  参数: <应用名> <xsa路径> <Vitis工作区路径>
#
#  流程:
#      1. 由 .xsa 建 platform（含 FSBL + BSP）
#      2. 建 application（hello world 模板）
#      3. 编译出 .elf
#
#  说明:
#      · Vitis Classic 2023.2 建议用 xsct 命令行而非 GUI，可全自动
#      · 首次运行会下载/生成 BSP，约 2~5 分钟
# =============================================================================

set appname [lindex $argv 0]
set xsa     [lindex $argv 1]
set ws      [lindex $argv 2]

if {$appname eq "" || $xsa eq "" || $ws eq ""} {
    puts "!!!ARGS!!! build_app.tcl 需要: <应用名> <xsa路径> <工作区路径>"
    exit 1
}

if {![file exists $xsa]} {
    puts "!!!NOXSA!!! 找不到硬件平台: $xsa"
    exit 1
}

puts "============================================================"
puts " \[build_app\] $appname"
puts "   xsa     : $xsa"
puts "   workdir : $ws"
puts "============================================================"

setws $ws

set pfm_name "${appname}_platform"

# --------------------------- 1. Platform ------------------------------------
if {[lsearch -exact [platform list] $pfm_name] < 0} {
    puts "\[build_app\] 创建 platform: $pfm_name"
    if {[catch {
        platform create -name $pfm_name -hw $xsa -os standalone -proc ps7_cortexa9_0
    } e]} {
        puts "!!!PLATFORM_FAILED!!! $e"
        exit 1
    }
} else {
    puts "\[build_app\] platform 已存在: $pfm_name"
}

platform active $pfm_name

# --------------------------- 2. Application ---------------------------------
if {[lsearch -exact [app list] $appname] < 0} {
    puts "\[build_app\] 创建 application: $appname"
    if {[catch {
        app create -name $appname -platform $pfm_name -domain standalone_domain -template "Empty Application(C)"
    } e]} {
        puts "!!!APP_FAILED!!! $e"
        exit 1
    }
} else {
    puts "\[build_app\] application 已存在: $appname"
}

app active $appname

# --------------------------- 3. 编译 ----------------------------------------
puts "\[build_app\] 编译 ..."
if {[catch {
    app build -name $appname
} e]} {
    puts "!!!BUILD_FAILED!!! $e"
    exit 1
}

# --------------------------- 4. 产物 ----------------------------------------
set elf [glob -nocomplain -directory [file join $ws $appname Debug] *.elf]
if {[llength $elf] == 0} {
    set elf [glob -nocomplain -directory $ws *.elf]
}
puts "ELF=$elf"
puts "BUILD_APP_OK"
