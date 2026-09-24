#!/usr/bin/env bash
# =============================================================================
#  env_check.sh —— ACZ7015 开发环境一键自检
# =============================================================================
#  用法:
#      ./scripts/env_check.sh
#      XILINX_ROOT=/d/Xilinx ./scripts/env_check.sh      # 工具装在别处时
#
#  退出码: 0 = 就绪, 1 = 有失败项
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PASS=0; FAIL=0; WARN=0
p_ok()   { ok   "$1"; PASS=$((PASS+1)); }
p_bad()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$1"; FAIL=$((FAIL+1)); }
p_warn() { warn "$1"; WARN=$((WARN+1)); }
sub()    { printf '%s         %s%s\n' "$C_DIM" "$1" "$C_RST"; }

section() { printf '\n%s=== %s ===%s\n' "$C_CYN" "$1" "$C_RST"; }

# 需要 Windows 侧的查询时走 PowerShell
ps() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null; }

# =============================================================================
section "1. Xilinx 工具链"

if [ -f "$VIVADO_BIN" ]; then
  p_ok "Vivado ${VIVADO_VER}   $(winpath "$VIVADO_BIN")"
else
  p_bad "Vivado 未找到: $(winpath "$VIVADO_BIN")"
fi

if [ -f "${XILINX_ROOT}/Vitis/${VIVADO_VER}/bin/vitis.bat" ]; then
  p_ok "Vitis ${VIVADO_VER}"
else
  p_bad "Vitis 未安装（PS 端开发不可用）"
fi

if [ -f "$XSCT_BIN" ]; then
  p_ok "XSCT 命令行（PS 端可脚本化）"
else
  p_warn "xsct 未找到"
fi

GCC="${XILINX_ROOT}/Vitis/${VIVADO_VER}/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe"
if [ -f "$GCC" ]; then
  ver="$("$GCC" --version 2>/dev/null | head -n1)"
  p_ok "ARM 交叉编译器   ${ver:-（无法执行）}"
else
  p_bad "ARM GCC 缺失"
fi

if [ -f "${XILINX_ROOT}/Vitis_HLS/${VIVADO_VER}/bin/vitis_hls.bat" ]; then
  p_ok "Vitis HLS ${VIVADO_VER}"
else
  p_warn "Vitis HLS 未找到（非必需）"
fi

# =============================================================================
section "2. 器件支持"

PART_DIR="${XILINX_ROOT}/Vivado/${VIVADO_VER}/data/parts/xilinx/zynq/devint/zynq/xc7z015"
if [ -d "$PART_DIR" ]; then
  p_ok "器件数据 ${PART} 已安装"
  [ -d "${PART_DIR}/clg485" ] && p_ok "CLG485 封装数据完整" || p_bad "CLG485 封装数据缺失"
else
  p_bad "器件数据未找到"
fi

MIG="${XILINX_ROOT}/Vivado/${VIVADO_VER}/data/ip/xilinx/mig_7series_v4_2/data/mem_tlib/ddr3_sdram/components"
if [ -f "${MIG}/mt41k256m16xx-125.xml" ]; then
  p_ok "MIG DDR3 器件 MT41K256M16XX-125 可用"
else
  p_warn "MIG DDR3 器件库未找到"
fi

# =============================================================================
section "3. ACZ7015 板级支持"

BXML="$(find "$BOARD_REPO" -name board.xml -print -quit 2>/dev/null)"
PXML="$(find "$BOARD_REPO" -name part0_pins.xml -print -quit 2>/dev/null)"
RXML="$(find "$BOARD_REPO" -name preset.xml -print -quit 2>/dev/null)"

[ -n "$BXML" ] && p_ok "board.xml"      || p_bad "board.xml 缺失（$BOARD_REPO）"
[ -n "$PXML" ] && p_ok "part0_pins.xml" || p_bad "part0_pins.xml 缺失"
[ -n "$RXML" ] && p_ok "preset.xml"     || p_bad "preset.xml 缺失"

# XML 语法快检（用 python，比 grep 靠谱）
if command -v python >/dev/null 2>&1; then
  for f in "$BXML" "$PXML" "$RXML"; do
    [ -n "$f" ] || continue
    if python -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$(winpath "$f")" 2>/dev/null; then
      p_ok "XML 语法 OK   $(basename "$f")"
    else
      p_bad "XML 语法错误 $(basename "$f")"
    fi
  done
fi

# =============================================================================
section "4. 驱动"

DRV_COUNT="$(ps "(Get-ChildItem 'C:\Windows\System32\drivers' -Filter 'CH34*' -ErrorAction SilentlyContinue).Count")"
if [ "${DRV_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  p_ok "串口驱动文件已就位（CH34x x${DRV_COUNT}）"
else
  p_bad "未找到 CH34x 串口驱动文件"
fi

STORE="$(ps "(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -ErrorAction SilentlyContinue | Where-Object { \$_.Name -match 'ch343' } | Select-Object -First 1).Name")"
if [ -n "$STORE" ]; then
  p_ok "CH343 驱动已入 DriverStore"
else
  p_warn "CH343 驱动未入仓（插板后可能需手动安装）"
fi

CABLE_LOG="${XILINX_ROOT}/.xinstall/Vivado_${VIVADO_VER}/cable_driver_install.log"
if [ -f "$CABLE_LOG" ] && grep -q "Installation completed successfully" "$CABLE_LOG" 2>/dev/null; then
  p_ok "Vivado 电缆（JTAG）驱动安装成功"
else
  p_warn "电缆驱动日志异常"
fi

# =============================================================================
section "5. USB 设备与串口"

USB="$(ps "Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { \$_.InstanceId -match 'VID_1A86|VID_0403|VID_1443|VID_03FD|VID_04B4' } | ForEach-Object { \$_.FriendlyName }")"
if [ -n "$USB" ]; then
  p_ok "检测到板子相关 USB 设备:"
  echo "$USB" | while IFS= read -r l; do [ -n "$l" ] && sub "$l"; done
else
  p_warn "未检测到 WCH/FTDI/Digilent 类 USB 设备（板子未插或未上电）"
fi

PORTS="$(ps "[System.IO.Ports.SerialPort]::GetPortNames() -join ', '")"
if [ -n "$PORTS" ]; then
  p_ok "当前串口: $PORTS"
else
  p_warn "当前没有串口"
fi
sub "插板后应新增一个 CH9102 串口（USB-Enhanced-SERIAL CH9102）"

# =============================================================================
section "6. 磁盘空间"

for d in C D E; do
  line="$(ps "\$di = New-Object System.IO.DriveInfo('$d'); if (\$di.IsReady) { '{0:N1}|{1:N1}' -f (\$di.AvailableFreeSpace/1GB), (\$di.TotalSize/1GB) }")"
  if [ -n "$line" ]; then
    free="${line%%|*}"; total="${line##*|}"
    msg="$d: 可用 ${free} GB / 共 ${total} GB"
    # 小于 10 GB 报警
    intfree="${free%%.*}"
    if [ "${intfree:-0}" -lt 10 ] 2>/dev/null; then p_warn "$msg"; else p_ok "$msg"; fi
  fi
done

# =============================================================================
section "7. 脚本与模板"

declare -a CHECKS=(
  "constrs/acz7015/acz7015.xdc|板级引脚约束"
  "constrs/acz7015/pinmap.csv|引脚速查表"
  "board/acz7015/ps7_preset.tcl|PS7 板级预设"
  "scripts/build.sh|构建入口脚本"
  "scripts/env_check.sh|本自检脚本"
  "scripts/tcl/create_pl_project.tcl|纯 PL 工程模板"
  "scripts/tcl/create_zynq_project.tcl|Zynq 工程模板"
  "scripts/tcl/register_board.tcl|板卡注册脚本"
)
for c in "${CHECKS[@]}"; do
  f="${c%%|*}"; desc="${c##*|}"
  [ -f "${REPO_ROOT}/${f}" ] && p_ok "$desc" || p_bad "缺失: $f"
done

# ---- 换行符自检（bash 脚本必须是 LF）----
crlf=""
while IFS= read -r sh; do
  if grep -qU $'\r' "$sh" 2>/dev/null; then crlf="$crlf ${sh#"$REPO_ROOT/"}"
  fi
done < <(find "${SCRIPTS_DIR}" -name '*.sh' -type f 2>/dev/null)

if [ -z "$crlf" ]; then
  p_ok "bash 脚本换行符检查（全部 LF）"
else
  p_bad "以下脚本是 CRLF 换行，Git Bash 会报错:$crlf"
  sub "修复: dos2unix scripts/**/*.sh   或   sed -i 's/\r$//' <文件>"
fi

# =============================================================================
printf '\n'
hr
printf '  自检汇总:  %s通过 %d%s   %s警告 %d%s   %s失败 %d%s\n' \
       "$C_GRN" "$PASS" "$C_RST" "$C_YLW" "$WARN" "$C_RST" "$C_RED" "$FAIL" "$C_RST"
hr

if [ "$FAIL" -eq 0 ]; then
  printf '%s  环境就绪。%s\n' "$C_GRN" "$C_RST"
  exit 0
else
  printf '%s  存在失败项，请先处理标 [FAIL] 的条目。%s\n' "$C_RED" "$C_RST"
  exit 1
fi
