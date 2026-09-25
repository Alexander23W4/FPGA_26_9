<#
  emmc_add.ps1 -- PC side of the eMMC loader.

  Sends a .bin file to the board over the USB-UART link and prints the
  board's write + read-back verification report.

  Link : PC --USB--> CH9102F --> PS UART1 (MIO48/49), 115200 8N1
  Board: csrc/MID_plt/src/main.c  (the "eMMC loader" application)

  Usage:
      powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_add.ps1 -File image.bin
      powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_add.ps1 -File image.bin -Port COM7 -StartBlock 2048

  Wire format (16-byte header, then the raw payload):
      [0..3]   magic  'E','M','M','C'
      [4..7]   payload length   (uint32, little endian)
      [8..11]  CRC32 of payload (uint32, little endian)
      [12..15] start block      (uint32, little endian)

  The board answers with plain text and ends its report with "===== END =====".
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$Port = 'COM7',
    [int]$Baud = 115200,
    # 0 = let the board append it after the last image already on the eMMC
    [uint32]$StartBlock = 0,
    [int]$ReadyTimeoutSec = 30,
    [int]$ResultTimeoutSec = 300,
    [int]$ChunkSize = 4096,
    # Image geometry. It is stored in the eMMC catalog, and the D command
    # uses it to program the VDMA. Leave 0 to infer it from the file size.
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$Bpp = 2,
    [string]$ImageName = ''
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# CRC32 (poly 0xEDB88320), same algorithm as the board side
# --------------------------------------------------------------------------
# NOTE: all arithmetic is done in [int64] and masked to 32 bits on purpose.
# PowerShell parses 0xFFFFFFFF as Int32 -1, so [uint32]0xFFFFFFFF throws
# "Value was either too large or too small for a UInt32". Working in int64 and
# masking avoids every one of those cast traps.
# NOTE: the two constants below are written in DECIMAL on purpose.
# PowerShell parses a hex literal that fits in 32 bits as a SIGNED Int32, so
#   0xFFFFFFFF -> -1            (making "-band 0xFFFFFFFF" a silent no-op)
#   0xEDB88320 -> -306674912    (sign-extended, corrupting the polynomial)
# Using the unsigned decimal values avoids both traps.
$script:CrcPoly = 3988292384   # 0xEDB88320
$script:CrcMask = 4294967295   # 0xFFFFFFFF

$script:CrcTable = $null
function Get-CrcTable {
    if ($null -ne $script:CrcTable) { return $script:CrcTable }
    $poly = $script:CrcPoly
    $mask = $script:CrcMask
    $t = New-Object 'int64[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        $c = [int64]$i
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band 1) -ne 0) {
                $c = ($poly -bxor ($c -shr 1)) -band $mask
            } else {
                $c = $c -shr 1
            }
        }
        $t[$i] = $c
    }
    $script:CrcTable = $t
    return $t
}

function Get-Crc32 {
    param([byte[]]$Data)
    $t = Get-CrcTable
    $mask = $script:CrcMask
    $crc = [int64]$mask
    foreach ($b in $Data) {
        $idx = [int](($crc -bxor [int64]$b) -band 255)
        $crc = ($t[$idx] -bxor ($crc -shr 8)) -band $mask
    }
    return ($crc -bxor $mask) -band $mask
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $File)) {
    Write-Host "ERROR: file not found: $File" -ForegroundColor Red
    exit 1
}

$full   = (Resolve-Path -LiteralPath $File).Path
$bytes  = [System.IO.File]::ReadAllBytes($full)
$len    = [int64]$bytes.Length
$crc    = Get-Crc32 -Data $bytes

# --- geometry: infer from the file size when not given -----------------------
if ($Bpp -le 0) { $Bpp = 1 }
if ($Width -le 0 -or $Height -le 0) {
    $px = [int]($len / $Bpp)
    $root = [int][Math]::Floor([Math]::Sqrt([double]$px))
    if ($root -gt 0 -and ($root * $root) -eq $px) {
        $Width = $root; $Height = $root       # perfect square
    } else {
        $Width = $px;   $Height = 1           # not square: treat as 1-D
    }
}
if ([string]::IsNullOrWhiteSpace($ImageName)) {
    $ImageName = [System.IO.Path]::GetFileNameWithoutExtension($full)
}
# catalog names are 8.3 style, so truncate to 8 characters
if ($ImageName.Length -gt 8) { $ImageName = $ImageName.Substring(0, 8) }

Write-Host "file       : $full"
Write-Host "size       : $($len) bytes"
Write-Host ("crc32      : 0x{0:X8}" -f $crc)
Write-Host "port       : $Port @ $Baud"
if ($StartBlock -eq 0) {
Write-Host "start block: auto (appended after the last image on the eMMC)"
} else {
    Write-Host "start block: $StartBlock  (byte offset $($StartBlock * 512))"
}
Write-Host "geometry   : ${Width} x ${Height}, $Bpp byte/px   name='$ImageName'"
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
    Write-Host "       Is the board powered and is its USB-UART cable plugged in?"
    Write-Host "       Close any serial terminal that may hold the port."
    exit 1
}

$sb = New-Object System.Text.StringBuilder

# --- send the command byte first: that is how the board enters a feature ----
# The board sits in its command loop waiting for that byte (see src/app.c)
Write-Host "sending command 'A' (add image to eMMC) ..."
$sp.Write([byte[]]@([byte][char]'A'), 0, 1)
$sp.BaseStream.Flush()

Write-Host "waiting for the board to print READY ..."
if (-not (Wait-ForText -Sp $sp -Sb $sb -Needle 'READY' -TimeoutSec $ReadyTimeoutSec)) {
    Write-Host "ERROR: timed out waiting for READY." -ForegroundColor Red
    Write-Host "--- what the board sent so far ---"
    Write-Host $sb.ToString()
    Write-Host "----------------------------------"
    Write-Host "The board is probably not running the loader, or it already stopped."
    Write-Host "Re-flash it:  scripts\\tcl\\flash_app.tcl <elf> <ps7_init.tcl> init"
    $sp.Close()
    exit 1
}

[void]$sb.Clear()

# --- send header -----------------------------------------------------------
# Built as a plain byte[40] by direct indexing. Do NOT use a
# List[byte] + AddRange here: PowerShell returns arrays from functions through
# the pipeline, which re-wraps them as Object[] and makes AddRange fail with
# "Cannot convert ... System.Object[] ... to IEnumerable`1[System.Byte]".
$hdr = New-Object 'byte[]' 40
$hdr[0]  = [byte][char]'E'
$hdr[1]  = [byte][char]'M'
$hdr[2]  = [byte][char]'M'
$hdr[3]  = [byte][char]'C'
$hdr[4]  = [byte]($len -band 0xFF)
$hdr[5]  = [byte](($len -shr 8)  -band 0xFF)
$hdr[6]  = [byte](($len -shr 16) -band 0xFF)
$hdr[7]  = [byte](($len -shr 24) -band 0xFF)
$hdr[8]  = [byte]($crc -band 0xFF)
$hdr[9]  = [byte](($crc -shr 8)  -band 0xFF)
$hdr[10] = [byte](($crc -shr 16) -band 0xFF)
$hdr[11] = [byte](($crc -shr 24) -band 0xFF)
$hdr[12] = [byte]($StartBlock -band 0xFF)
$hdr[13] = [byte](($StartBlock -shr 8)  -band 0xFF)
$hdr[14] = [byte](($StartBlock -shr 16) -band 0xFF)
$hdr[15] = [byte](($StartBlock -shr 24) -band 0xFF)
$hdr[16] = [byte]($Width  -band 0xFF)
$hdr[17] = [byte](($Width  -shr 8) -band 0xFF)
$hdr[18] = [byte]($Height -band 0xFF)
$hdr[19] = [byte](($Height -shr 8) -band 0xFF)
$hdr[20] = [byte]($Bpp    -band 0xFF)
$hdr[21] = [byte](($Bpp    -shr 8) -band 0xFF)
$hdr[22] = [byte]0
$hdr[23] = [byte]0
$nameBytes = [System.Text.Encoding]::ASCII.GetBytes($ImageName)
for ($i = 0; $i -lt 16; $i++) {
    if ($i -lt $nameBytes.Length -and $i -lt 15) { $hdr[24 + $i] = $nameBytes[$i] }
    else { $hdr[24 + $i] = [byte]0 }
}
$sp.Write($hdr, 0, 40)
$sp.BaseStream.Flush()

# --- send payload in chunks ------------------------------------------------
Write-Host "sending $len bytes ..."
$sent = 0
while ($sent -lt $len) {
    $n = [Math]::Min($ChunkSize, [int]($len - $sent))
    $sp.Write($bytes, [int]$sent, [int]$n)
    $sent += $n
    [Console]::Write("`r  $sent / $len")
    Start-Sleep -Milliseconds 2
}
[Console]::WriteLine("`r  $sent / $len  (sent)")
$sp.BaseStream.Flush()

Write-Host ""
Write-Host "waiting for the board's verification report ..."
Write-Host "--------------------------------------------------------------"

$ok = Wait-ForText -Sp $sp -Sb $sb -Needle '===== END =====' -TimeoutSec $ResultTimeoutSec

Write-Host $sb.ToString()
Write-Host "--------------------------------------------------------------"
$sp.Close()

if (-not $ok) {
    Write-Host "WARNING: the board did not print the end marker (timeout)." -ForegroundColor Yellow
    exit 2
}

$text = $sb.ToString()
if ($text -match 'RESULT:\s*VERIFY OK') {
    Write-Host "SUCCESS: the image was written to eMMC and read back identical." -ForegroundColor Green
    exit 0
}
if ($text -match 'VERIFY FAILED') {
    Write-Host "FAILED: read-back differs from what was written." -ForegroundColor Red
    exit 3
}
Write-Host "The board stopped before verifying (see its report above)." -ForegroundColor Yellow
exit 4
