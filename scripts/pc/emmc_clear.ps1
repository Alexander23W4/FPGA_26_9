<#
  emmc_clear.ps1 -- wipe the eMMC: erase all registered images and reset

  Usage: powershell -ExecutionPolicy Bypass -File scripts\pc\emmc_clear.ps1
#>
[CmdletBinding()]
param([string]$Port='COM7', [int]$Baud=115200, [int]$TimeoutSec=300)
$ErrorActionPreference='Stop'
$sp = New-Object System.IO.Ports.SerialPort($Port,$Baud,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$sp.ReadTimeout=300; $sp.Encoding=[System.Text.Encoding]::UTF8
try { $sp.Open() } catch { Write-Host "cannot open $Port : $($_.Exception.Message)"; exit 1 }
$sp.Write([byte[]]@([byte][char]'E'),0,1); $sp.BaseStream.Flush()
$sb = New-Object System.Text.StringBuilder; $buf = New-Object char[] 4096
$dl = (Get-Date).AddSeconds($TimeoutSec)
while((Get-Date) -lt $dl){ try{ $n=$sp.Read($buf,0,4096); if($n -gt 0){ [void]$sb.Append($buf,0,$n); if($sb.ToString().Contains('===== END =====')){break} } }catch{} }
$sp.Close()
Write-Host $sb.ToString()
