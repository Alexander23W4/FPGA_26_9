<#
  net_recv.ps1 -- receive the result image that the board sends over UDP.

  Board side : csrc/MID_plt/src/feat_net_send.c  (serial command 'N')
  Link       : board PS ENET0 -> RTL8211F -> RJ45 -> laptop USB-Ethernet adapter
  Board      : 192.168.1.10:5001  ->  192.168.1.100:5000

  Put the laptop adapter on 192.168.1.100 / 255.255.255.0 first, e.g.
      netsh interface ip set address "Ethernet 2" static 192.168.1.100 255.255.255.0

  Packet format (16 byte header + payload):
      [0..3]   magic  'M','I','D','1'
      [4..7]   frame id   (u32 LE)
      [8..11]  offset     (u32 LE)
      [12..15] total size (u32 LE)
      [16..]   payload

  Usage:
      powershell -ExecutionPolicy Bypass -File scripts\pc\net_recv.ps1
      powershell -ExecutionPolicy Bypass -File scripts\pc\net_recv.ps1 -Out D:\result.bin
#>

[CmdletBinding()]
param(
    [int]$Port = 5000,
    [string]$Out = 'result.bin',
    [int]$TimeoutSec = 40,
    [int]$Width = 256,
    [int]$Height = 256,
    [int]$Bpp = 2
)

$ErrorActionPreference = 'Stop'

$total

Write-Host "listening on UDP port $Port ..."
Write-Host "expecting board 192.168.1.10:5001 -> this PC 192.168.1.100:$Port"
Write-Host ""

$udp = New-Object System.Net.Sockets.UdpClient($Port)
$udp.Client.ReceiveTimeout = 1000

$data   = $null
$seen   = @{}          # offset -> 1, to count duplicates / missing pieces
$frame  = -1
$expect = 0
$bytes  = 0

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$remote   = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

while ((Get-Date) -lt $deadline) {
    try {
        $pkt = $udp.Receive([ref]$remote)
    } catch {
        if ($seen.Count -gt 0 -and $bytes -ge $expect -and $expect -gt 0) { break }
        continue
    }

    if ($pkt.Length -lt 16) { continue }
    if (-not ($pkt[0] -eq [byte][char]'M' -and $pkt[1] -eq [byte][char]'I' -and
              $pkt[2] -eq [byte][char]'D' -and $pkt[3] -eq [byte][char]'1')) { continue }

    $fid = [BitConverter]::ToUInt32($pkt, 4)
    $off = [BitConverter]::ToUInt32($pkt, 8)
    $tot = [BitConverter]::ToUInt32($pkt, 12)

    if ($data -eq $null -or $tot -ne $expect) {
        $expect = $tot
        $data   = New-Object byte[] $expect
        Write-Host ("frame {0}: expecting {1} bytes" -f $fid, $expect)
    }
    $frame = $fid

    $n = $pkt.Length - 16
    if (($off + $n) -gt $expect) { $n = $expect - $off }

    [Array]::Copy($pkt, 16, $data, $off, $n)

    if (-not $seen.ContainsKey($off)) {
        $seen[$off] = 1
        $bytes += $n
        [Console]::Write("`r  received {0} / {1} bytes  ({2} packets)" -f $bytes, $expect, $seen.Count)
    }

    if ($bytes -ge $expect) { break }
}

[Console]::WriteLine("")
$udp.Close()

if ($data -eq $null -or $expect -eq 0) {
    Write-Host "ERROR: nothing received." -ForegroundColor Red
    Write-Host "  - is the board powered and running the app?"
    Write-Host "  - did you press 'N' on the board's serial console?"
    Write-Host "  - is the laptop adapter on 192.168.1.100 / 255.255.255.0 ?"
    Write-Host "  - check which RJ45 jack is the PS one (it is the one that links up)"
    exit 1
}

$path = [System.IO.Path]::GetFullPath($Out)
[System.IO.File]::WriteAllBytes($path, $data)

Write-Host ""
Write-Host "saved      : $path"
Write-Host "frame id   : $frame"
Write-Host "bytes      : $bytes / $expect"
Write-Host ("first 16 B : " + (($data[0..15] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))

# quick sanity check: for a segmentation label map most pixels are 0 or 1
if ($Bpp -eq 2) {
    $px = [int]($data.Length / 2)
    $n0 = 0; $n1 = 0; $other = 0
    $vmin = 65535; $vmax = 0
    for ($i = 0; $i -lt $px; $i++) {
        $v = [BitConverter]::ToUInt16($data, $i * 2)
        if ($v -eq 0) { $n0++ } elseif ($v -eq 1) { $n1++ } else { $other++ }
        if ($v -lt $vmin) { $vmin = $v }
        if ($v -gt $vmax) { $vmax = $v }
    }
    Write-Host ""
    Write-Host "pixels     : $px   (${Width} x ${Height})"
    Write-Host "value 0    : $n0"
    Write-Host "value 1    : $n1"
    Write-Host "other      : $other"
    Write-Host "min / max  : $vmin / $vmax"
    if ($other -eq 0) {
        Write-Host "-> the result is a clean 0/1 label map: segmentation output looks right." -ForegroundColor Green
    } else {
        Write-Host "-> values other than 0/1 present. If your algorithm outputs a probability" -ForegroundColor Yellow
        Write-Host "   or grey level map that is expected; otherwise check the PL side."
    }
}

if ($bytes -lt $expect) {
    Write-Host ""
    Write-Host "WARNING: incomplete frame (some packets were lost)." -ForegroundColor Yellow
    exit 2
}
exit 0
