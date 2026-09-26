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

  The board side loops forever, so this streams its output until you press
  Ctrl+C, or until -TimeoutSec is reached (0 = forever).

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

$payload = [System.Text.Encoding]::ASCII.GetBytes($line)
$sp.Write($payload, 0, $payload.Length)
$sp.BaseStream.Flush()

$buf   = New-Object char[] 4096
$start = Get-Date

try {
    while ($true) {
        try {
            $n = $sp.Read($buf, 0, 4096)
            if ($n -gt 0) {
                [Console]::Write((-join $buf[0..($n - 1)]))
            }
        } catch [TimeoutException] { }

        if ($TimeoutSec -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $TimeoutSec) {
            Write-Host ""
            Write-Host "stopped: reached -TimeoutSec $TimeoutSec"
            break
        }
    }
} finally {
    $sp.Close()
}
