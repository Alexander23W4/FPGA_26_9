<#
  emmc_to_ddr.ps1 -- PC side of the "eMMC -> DDR -> VDMA" feature.

  Tells the board which image (by index in the eMMC catalog) to load into
  PS DDR, and the board then programs and starts the AXI VDMA MM2S.

  Board side : csrc/MID_plt/src/feat/feat_img2ddr.c
  Command    : 'D' followed by a 4-byte little-endian image index

  Usage:
      powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_to_ddr.ps1
      powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_to_ddr.ps1 -Index 1 -Port COM7
#>

[CmdletBinding()]
param(
    [string]$Port = 'COM7',
    [int]$Baud = 115200,
    [uint32]$Index = 0,
    [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'

function Wait-ForText {
    param(
        [System.IO.Ports.SerialPort]$Sp,
        [System.Text.StringBuilder]$Sb,
        [string]$Needle,
        [int]$TimeoutSec
    )
    $buf = New-Object char[] 4096
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $Sp.Read($buf, 0, 4096)
            if ($n -gt 0) {
                [void]$Sb.Append($buf, 0, $n)
                if ($Sb.ToString().Contains($Needle)) { return $true }
            }
        } catch [TimeoutException] { }
    }
    return $false
}

Write-Host "port  : $Port @ $Baud"
Write-Host "index : $Index  (0 = first image)"
Write-Host ""

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
    exit 1
}

$sb = New-Object System.Text.StringBuilder

# 'D' = eMMC -> DDR, and start the VDMA
$sp.Write([byte[]]@([byte][char]'D'), 0, 1)
$sp.BaseStream.Flush()

# then the 4-byte little-endian index (the board waits for it at SELECT)
$idx = New-Object 'byte[]' 4
$idx[0] = [byte]($Index -band 0xFF)
$idx[1] = [byte](($Index -shr 8)  -band 0xFF)
$idx[2] = [byte](($Index -shr 16) -band 0xFF)
$idx[3] = [byte](($Index -shr 24) -band 0xFF)
$sp.Write($idx, 0, 4)
$sp.BaseStream.Flush()

Write-Host "waiting for the board ..."
Write-Host "--------------------------------------------------------------"

$ok = Wait-ForText -Sp $sp -Sb $sb -Needle '===== END =====' -TimeoutSec $TimeoutSec

Write-Host $sb.ToString()
Write-Host "--------------------------------------------------------------"
$sp.Close()

if (-not $ok) {
    Write-Host "WARNING: timed out waiting for the end marker." -ForegroundColor Yellow
    exit 2
}

$text = $sb.ToString()

# The frame pointer only advances once the PL consumes M_AXIS_MM2S, so there are
# two distinct good outcomes. Both are reported as success.
if ($text -match 'RESULT:\s*OK -- eMMC -> DDR -> VDMA') {
    Write-Host "FULL CHAIN OK: eMMC -> DDR -> VDMA -> AXI-Stream, data really flowed." -ForegroundColor Green
    exit 0
}
if ($text -match 'RESULT:\s*OK -- eMMC -> DDR ready, VDMA started') {
    Write-Host "OK: eMMC -> DDR verified, and the VDMA started with no error bits." -ForegroundColor Green
    Write-Host "The frame counter stays at 0 because M_AXIS_MM2S has no consumer yet."
    Write-Host "Attach your PL module to axi_vdma_0/M_AXIS_MM2S and drive tready:"
    Write-Host "this same command will then report the full chain as OK."
    exit 0
}
if ($text -match 'DDR READY, VDMA ABSENT') {
    Write-Host "Image is in DDR and CRC-verified, but the design has no VDMA yet." -ForegroundColor Yellow
    Write-Host "Re-synthesise with -H so axi_vdma_0 is in the bitstream."
    exit 5
}
if ($text -match 'RESULT:\s*FAILED') {
    Write-Host "FAILED: the board stopped at one of the numbered steps above." -ForegroundColor Red
    exit 3
}
Write-Host "The board finished, but printed no RESULT line (see its output above)." -ForegroundColor Yellow
exit 4
