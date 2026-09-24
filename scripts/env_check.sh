#!/usr/bin/env bash
# =============================================================================
#  env_check.sh —— ACZ7015 开发环境一键自检
# =============================================================================
#  用法:
#      ./scripts/env_check.sh
#      XILINX_ROOT=/d/Xilinx ./scripts/env_check.sh      # 工具装在别处时
#
#  退出码: 0 = 就绪, 1 = 有失败项
#
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PASS=0; FAIL=0; WARN=0
p_ok()   { ok   "$1"; PASS=$((PASS+1)); }
p_bad()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$1"; FAIL=$((FAIL+1)); }
p_warn() { warn "$1"; WARN=$((WARN+1)); }
sub()    { printf '%s           %s%s\n' "$C_DIM" "$1" "$C_RST"; }

section() { printf '\n%s=== %s ===%s\n' "$C_CYN" "$1" "$C_RST"; }

# 需要 Windows 侧的查询时走 PowerShell
ps() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null; }

# =============================================================================
section "1. Xilinx toolchain"

if [ -f "$VIVADO_BIN" ]; then
  p_ok "Vivado ${VIVADO_VER}   $(winpath "$VIVADO_BIN")"
else
  p_bad "Vivado not found: $(winpath "$VIVADO_BIN")"
fi

if [ -f "${XILINX_ROOT}/Vitis/${VIVADO_VER}/bin/vitis.bat" ]; then
  p_ok "Vitis ${VIVADO_VER}"
else
  p_bad "Vitis not installed (PS-side development unavailable)"
fi

if [ -f "$XSCT_BIN" ]; then
  p_ok "XSCT command line (PS side can be scripted)"
else
  p_warn "xsct not found"
fi

GCC="${XILINX_ROOT}/Vitis/${VIVADO_VER}/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe"
if [ -f "$GCC" ]; then
  ver="$("$GCC" --version 2>/dev/null | head -n1)"
  p_ok "ARM cross compiler   ${ver:-（not executable）}"
else
  p_bad "ARM GCC missing"
fi

if [ -f "${XILINX_ROOT}/Vitis_HLS/${VIVADO_VER}/bin/vitis_hls.bat" ]; then
  p_ok "Vitis HLS ${VIVADO_VER}"
else
  p_warn "Vitis HLS not found (optional)"
fi

# =============================================================================
section "2. Device support"

PART_DIR="${XILINX_ROOT}/Vivado/${VIVADO_VER}/data/parts/xilinx/zynq/devint/zynq/xc7z015"
if [ -d "$PART_DIR" ]; then
  p_ok "Device data for ${PART} is installed"
  [ -d "${PART_DIR}/clg485" ] && p_ok "CLG485 package data complete" || p_bad "CLG485 package data missing"
else
  p_bad "Device data not found"
fi

MIG="${XILINX_ROOT}/Vivado/${VIVADO_VER}/data/ip/xilinx/mig_7series_v4_2/data/mem_tlib/ddr3_sdram/components"
if [ -f "${MIG}/mt41k256m16xx-125.xml" ]; then
  p_ok "MIG DDR3 part MT41K256M16XX-125 available"
else
  p_warn "MIG DDR3 part library not found"
fi

# =============================================================================
section "3. ACZ7015 board support"

BXML="$(find "$BOARD_REPO" -name board.xml -print -quit 2>/dev/null)"
PXML="$(find "$BOARD_REPO" -name part0_pins.xml -print -quit 2>/dev/null)"
RXML="$(find "$BOARD_REPO" -name preset.xml -print -quit 2>/dev/null)"

[ -n "$BXML" ] && p_ok "board.xml"      || p_bad "board.xml missing ($BOARD_REPO)"
[ -n "$PXML" ] && p_ok "part0_pins.xml" || p_bad "part0_pins.xml missing"
[ -n "$RXML" ] && p_ok "preset.xml"     || p_bad "preset.xml missing"

# XML 语法快检（用 python，比 grep 靠谱）
if command -v python >/dev/null 2>&1; then
  for f in "$BXML" "$PXML" "$RXML"; do
    [ -n "$f" ] || continue
    if python -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$(winpath "$f")" 2>/dev/null; then
      p_ok "XML syntax OK    $(basename "$f")"
    else
      p_bad "XML syntax ERROR $(basename "$f")"
    fi
  done
fi

# =============================================================================
section "4. Drivers"

DRV_COUNT="$(ps "(Get-ChildItem 'C:\Windows\System32\drivers' -Filter 'CH34*' -ErrorAction SilentlyContinue).Count")"
if [ "${DRV_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  p_ok "Serial driver files present (CH34x x${DRV_COUNT})"
else
  p_bad "CH34x serial driver files not found"
fi

STORE="$(ps "(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -ErrorAction SilentlyContinue | Where-Object { \$_.Name -match 'ch343' } | Select-Object -First 1).Name")"
if [ -n "$STORE" ]; then
  p_ok "CH343 driver staged in DriverStore"
else
  p_warn "CH343 driver not staged (may need manual install after plugging in)"
fi

CABLE_LOG="${XILINX_ROOT}/.xinstall/Vivado_${VIVADO_VER}/cable_driver_install.log"
if [ -f "$CABLE_LOG" ] && grep -q "Installation completed successfully" "$CABLE_LOG" 2>/dev/null; then
  p_ok "Vivado cable (JTAG) driver installed"
else
  p_warn "Cable driver log looks wrong"
fi

# =============================================================================
section "5. USB devices and serial ports"

USB="$(ps "Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -match 'VID_1A86|VID_0403|VID_1443|VID_03FD|VID_04B4' } | ForEach-Object { \$_.FriendlyName }")"
if [ -n "$USB" ]; then
  p_ok "Board-related USB device(s) detected:"
  echo "$USB" | while IFS= read -r l; do [ -n "$l" ] && sub "$l"; done
else
  p_warn "No WCH/FTDI/Digilent USB device detected (board not plugged in or not powered)"
fi

PORTS="$(ps "[System.IO.Ports.SerialPort]::GetPortNames() -join ', '")"
if [ -n "$PORTS" ]; then
  p_ok "Current serial ports: $PORTS"
else
  p_warn "No serial ports"
fi
sub "After plugging in, expect one more: USB-Enhanced-SERIAL CH9102 (COMx)"

# =============================================================================
section "6. Disk space"

for d in C D E; do
  line="$(ps "\$di = New-Object System.IO.DriveInfo('$d'); if (\$di.IsReady) { '{0:N1}|{1:N1}' -f (\$di.AvailableFreeSpace/1GB), (\$di.TotalSize/1GB) }")"
  if [ -n "$line" ]; then
    free="${line%%|*}"; total="${line##*|}"
    msg="$d: free ${free} GB / total ${total} GB"
    intfree="${free%%.*}"
    if [ "${intfree:-0}" -lt 10 ] 2>/dev/null; then p_warn "$msg"; else p_ok "$msg"; fi
  fi
done

# =============================================================================
section "7. Scripts and templates"

declare -a CHECKS=(
  "constrs/acz7015/acz7015.xdc|Board pin reference"
  "constrs/acz7015/pinmap.csv|Pin lookup table"
  "board/acz7015/ps7_preset.tcl|PS7 board preset"
  "scripts/build.sh|Build entry script"
  "scripts/env_check.sh|This self-check script"
  "scripts/tcl/create_pl_project.tcl|PL project template"
  "scripts/tcl/create_zynq_project.tcl|Zynq project template"
  "scripts/tcl/register_board.tcl|Board registration script"
)
for c in "${CHECKS[@]}"; do
  f="${c%%|*}"; desc="${c##*|}"
  [ -f "${REPO_ROOT}/${f}" ] && p_ok "$desc" || p_bad "Missing: $f"
done

# ---- 换行符自检（bash 脚本必须是 LF）----
crlf=""
while IFS= read -r sh; do
  if grep -qU $'\r' "$sh" 2>/dev/null; then crlf="$crlf ${sh#"$REPO_ROOT/"}"
  fi
done < <(find "${SCRIPTS_DIR}" -name '*.sh' -type f 2>/dev/null)

if [ -z "$crlf" ]; then
  p_ok "Line endings check (all LF)"
else
  p_bad "CRLF line endings found (Git Bash will fail):$crlf"
  sub "Fix: dos2unix scripts/**/*.sh   or   sed -i 's/\r\$//' <file>"
fi

# =============================================================================
printf '\n'
hr
printf '  Summary:  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' \
       "$C_GRN" "$PASS" "$C_RST" "$C_YLW" "$WARN" "$C_RST" "$C_RED" "$FAIL" "$C_RST"
hr

if [ "$FAIL" -eq 0 ]; then
  printf '%s  Environment ready.%s\n' "$C_GRN" "$C_RST"
  exit 0
else
  printf '%s  Some checks failed. Fix the [FAIL] items above.%s\n' "$C_RED" "$C_RST"
  exit 1
fi
