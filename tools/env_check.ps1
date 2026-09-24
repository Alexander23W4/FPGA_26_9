<#
.SYNOPSIS
    ACZ7015 开发环境一键自检

.DESCRIPTION
    检查工具链、器件支持、板卡文件、驱动、串口、磁盘，
    并给出通过/失败汇总。

.PARAMETER Verbose
    输出更多细节

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\env_check.ps1

.NOTES
    器件 : xc7z015clg485-2
    板子 : 小梅哥 ACZ7015 (Zynq-7015)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# ============================== 常量 ========================================
$REPO_ROOT   = Split-Path -Parent $PSScriptRoot
$XILINX_ROOT = 'E:\Xilinx'
$VIVADO      = "$XILINX_ROOT\Vivado\2023.2"
$VITIS       = "$XILINX_ROOT\Vitis\2023.2"
$VITIS_HLS   = "$XILINX_ROOT\Vitis_HLS\2023.2"
$PART        = 'xc7z015clg485-2'
$BOARD_REPO  = Join-Path $REPO_ROOT 'config\board'

$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host ("  [OK]   " + $m) -ForegroundColor Green;  $script:Pass++ }
function Bad($m)  { Write-Host ("  [FAIL] " + $m) -ForegroundColor Red;    $script:Fail++ }
function Warn2($m){ Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow; $script:Warn++ }
function Info($m) { Write-Host ("         " + $m) -ForegroundColor Gray }

function Test-Path2($p) { Test-Path -LiteralPath $p }

# ============================== 1. 工具链 ===================================
Section "1. Xilinx 工具链"

if (Test-Path2 $VIVADO) {
    Ok "Vivado 2023.2      $VIVADO"
    $vver = Join-Path $VIVADO 'bin\vivado.bat'
    if (Test-Path2 $vver) { Ok "vivado.bat 存在" } else { Bad "vivado.bat 缺失" }
} else { Bad "Vivado 2023.2 未找到 ($VIVADO)" }

if (Test-Path2 "$VITIS\bin\vitis.bat")          { Ok "Vitis 2023.2       $VITIS" }        else { Bad "Vitis 2023.2 未安装" }
if (Test-Path2 "$VITIS\bin\xsct.bat")           { Ok "XSCT 命令行" }                      else { Bad "xsct.bat 缺失" }

$gcc = "$VITIS\gnu\aarch32\nt\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe"
if (Test-Path2 $gcc) {
    $ver = (& $gcc --version 2>&1 | Select-Object -First 1)
    Ok "ARM 交叉编译器     $ver"
} else { Bad "ARM GCC 缺失（PS 裸机开发不可用）" }

if (Test-Path2 "$VITIS_HLS\bin\vitis_hls.bat")  { Ok "Vitis HLS 2023.2" }                 else { Warn2 "Vitis HLS 未找到（非必需）" }

# Vitis Classic
$sm = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Xilinx Design Tools"
if (Test-Path2 "$sm\Vitis 2023.2\Vitis Classic 2023.2.lnk") { Ok "Vitis Classic 2023.2 快捷方式（Zynq-7000 建议用它）" }
else { Warn2 "未找到 Vitis Classic 快捷方式" }

# ============================== 2. 器件支持 =================================
Section "2. 器件支持"

$partDir = "$VIVADO\data\parts\xilinx\zynq\devint\zynq\xc7z015"
if (Test-Path2 $partDir) {
    Ok "器件数据 $PART 已安装"
    if (Test-Path2 "$partDir\clg485") { Ok "CLG485 封装数据完整" } else { Bad "CLG485 封装数据缺失" }
} else { Bad "器件数据未找到，Vivado 可能不支持 $PART" }

$mig = "$VIVADO\data\ip\xilinx\mig_7series_v4_2\data\mem_tlib\ddr3_sdram\components"
if (Test-Path2 "$mig\mt41k256m16xx-125.xml") { Ok "MIG DDR3 器件 MT41K256M16XX-125 可用" }
else { Warn2 "MIG DDR3 器件库未找到（PS DDR 仍可用 PS7 内部控制器）" }

# ============================== 3. 板卡文件 =================================
Section "3. ACZ7015 板卡文件"

$bxml = (Get-ChildItem -Path $BOARD_REPO -Recurse -Filter 'board.xml'      -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
$pxml = (Get-ChildItem -Path $BOARD_REPO -Recurse -Filter 'part0_pins.xml' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
$rxml = (Get-ChildItem -Path $BOARD_REPO -Recurse -Filter 'preset.xml'     -ErrorAction SilentlyContinue | Select-Object -First 1).FullName

if (Test-Path2 $bxml) { Ok "board.xml" }      else { Bad "board.xml 缺失: $bxml" }
if (Test-Path2 $pxml) { Ok "part0_pins.xml" } else { Bad "part0_pins.xml 缺失" }
if (Test-Path2 $rxml) { Ok "preset.xml" }     else { Bad "preset.xml 缺失" }

# XML 语法快速校验
foreach ($f in @($bxml, $pxml, $rxml)) {
    if (Test-Path2 $f) {
        try { [xml]$null = Get-Content -LiteralPath $f -Raw; Ok ("XML 语法 OK  " + (Split-Path $f -Leaf)) }
        catch { Bad ("XML 语法错误 " + (Split-Path $f -Leaf) + " : " + $_.Exception.Message) }
    }
}

# ============================== 4. 驱动 =====================================
Section "4. 驱动"

$cp = Get-ChildItem 'C:\Windows\System32\drivers' -Filter 'CH34*' -ErrorAction SilentlyContinue
if ($cp) { Ok ("串口驱动文件: " + ($cp.Name -join ', ')) } else { Bad "未找到 CH34x 串口驱动文件" }

$store = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match 'ch343' }
if ($store) { Ok "CH343 驱动已入 DriverStore: $($store.Name)" } else { Warn2 "CH343 驱动未入仓（插板后可能需手动装）" }

$cable = "$XILINX_ROOT\.xinstall\Vivado_2023.2\cable_driver_install.log"
if (Test-Path2 $cable) {
    if (Select-String -LiteralPath $cable -Pattern 'Installation completed successfully' -Quiet) {
        Ok "Vivado 电缆（JTAG）驱动安装成功"
    } else { Warn2 "电缆驱动日志异常，见 $cable" }
} else { Warn2 "未找到电缆驱动安装日志" }

# ============================== 5. USB 设备 / 串口 ==========================
Section "5. USB 设备与串口"

$usb = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -match 'VID_1A86|VID_0403|VID_1443|VID_03FD|VID_04B4' }

if ($usb) {
    Ok "检测到板子相关 USB 设备:"
    $usb | ForEach-Object { Info ("  {0,-8} {1}  [{2}]" -f $_.Status, $_.FriendlyName, $_.InstanceId) }
} else {
    Warn2 "未检测到 WCH/FTDI/Digilent 类 USB 设备（板子未插或未上电）"
}

$ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
if ($ports) { Ok ("当前串口: " + ($ports -join ', ')) } else { Warn2 "当前没有串口" }
Info "插板后应新增一个 CH9102 串口（USB-Enhanced-SERIAL CH9102）"

# ============================== 6. 磁盘 =====================================
Section "6. 磁盘空间"

foreach ($d in @('C','D','E')) {
    try {
        $di = New-Object System.IO.DriveInfo($d)
        if ($di.IsReady) {
            $freeGB = [math]::Round($di.AvailableFreeSpace / 1GB, 1)
            $msg = ("{0}: 可用 {1} GB / 共 {2} GB" -f $d, $freeGB, [math]::Round($di.TotalSize / 1GB, 1))
            if ($freeGB -lt 10) { Warn2 $msg } else { Ok $msg }
        }
    } catch { }
}

# ============================== 7. 工程模板 =================================
Section "7. 工程模板与约束"

$files = @(
    @('config\acz7015.xdc',                '板级引脚约束（整理版）'),
    @('config\acz7015_ps7_preset.tcl',     'PS7 板级预设 Tcl'),
    @('tools\create_pl_project.tcl',       '纯 PL 工程模板'),
    @('tools\create_zynq_project.tcl',     'Zynq 工程模板'),
    @('tools\register_board.tcl',          '板卡注册脚本')
)
foreach ($f in $files) {
    $p = Join-Path $REPO_ROOT $f[0]
    if (Test-Path2 $p) { Ok $f[1] } else { Bad ("缺失: " + $f[0]) }
}

# ============================== 汇总 ========================================
Write-Host ""
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host ("  自检汇总:  通过 $script:Pass   警告 $script:Warn   失败 $script:Fail") -ForegroundColor Cyan
Write-Host ("=" * 56) -ForegroundColor Cyan

if ($script:Fail -eq 0) {
    Write-Host "  环境就绪。" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  存在失败项，请先处理上面标 [FAIL] 的条目。" -ForegroundColor Red
    exit 1
}
