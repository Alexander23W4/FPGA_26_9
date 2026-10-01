<#
  run_test.ps1 -- PC side: tell the board WHICH test to run.

  Sends exactly one line over the USB-UART link:

      -<Test>\n

  The board's src/main.c reads that whole line and looks the name up in its
  test table (the tests[] array at the top of main.c).

  Usage:
      powershell -ExecutionPolicy Bypass -File scripts\pc\run_test.ps1 -Test pl_ctrl_test
      powershell -ExecutionPolicy Bypass -File scripts\pc\run_test.ps1 -Test pl_ctrl_test -Port COM7
      powershell -ExecutionPolicy Bypass -File scripts\pc\run_test.ps1 -Test pl_ctrl_test -TimeoutSec 60

  The board side loops until this script closes. In finally (including Ctrl+C),
  the script sends '!' so pl_ctrl_test halts VDMA and returns to main's command
  loop. -TimeoutSec has the same stop behaviour (0 = forever).

  NOTE: close any serial terminal (SSCOM / putty) before running this -- it
        owns the COM port exclusively.
#>

[CmdletBinding()]
param(
    # Test name as registered on the board, with or without the leading '-'.
    [Parameter(Mandatory = $true)][string]$Test,

    [string]$Port = 'COM7',
    [int]$Baud = 115200,

    # 0 = stream until Ctrl+C
    [int]$TimeoutSec = 0
)

$ErrorActionPreference = 'Stop'

$name = $Test
if ($name.StartsWith('-')) { $name = $name.Substring(1) }
if ([string]::IsNullOrWhiteSpace($name)) {
    throw '-Test must not be empty'
}

$line = "-$name`n"

Write-Host "port : $Port @ $Baud"
Write-Host "test : $name"
Write-Host "send : $($line.TrimEnd())"
Write-Host "-------------------------------------------------------------------"

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 300
$sp.WriteTimeout = 5000
$sp.Encoding = [System.Text.Encoding]::UTF8
$sp.DtrEnable = $false
$sp.RtsEnable = $false

try {
    $sp.Open()
} catch {
    Write-Host "ERROR: cannot open $Port -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Board powered? USB-UART cable plugged in? Terminal closed?"
    exit 1
}

$testSent = $false
$payload = [System.Text.Encoding]::ASCII.GetBytes($line)
$sp.Write($payload, 0, $payload.Length)
$sp.BaseStream.Flush()
$testSent = $true

$buf   = New-Object byte[] 4096
$out   = [Console]::OpenStandardOutput()
$start = Get-Date

try {
    while ($true) {
        try {
            # 直接读原始字节, 原样吐到 stdout. 不走字符串解码,
            # 板子发的是 UTF-8, Git Bash 也是 UTF-8 -> 中文不会变乱码.
            $n = $sp.Read($buf, 0, 4096)
            if ($n -gt 0) {
                $out.Write($buf, 0, $n)
                $out.Flush()
            }
        } catch [TimeoutException] { }

        if ($TimeoutSec -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $TimeoutSec) {
            Write-Host ""
            Write-Host "stopped: reached -TimeoutSec $TimeoutSec"
            break
        }
    }
} finally {
    # Ctrl+C enters finally in PowerShell. The board test polls for this byte
    # during its delay, stops VDMA, and returns to the normal command loop.
    if ($testSent -and $sp.IsOpen) {
        try {
            $stop = [byte[]]@([byte][char]'!')
            $sp.Write($stop, 0, 1)
            $sp.BaseStream.Flush()
            Write-Host "`nrequesting board test stop ('!') ..."
            Start-Sleep -Milliseconds 100
        } catch {
            Write-Host "`nwarning: could not send board stop byte -- $($_.Exception.Message)"
        }
    }
    $sp.Close()
}
