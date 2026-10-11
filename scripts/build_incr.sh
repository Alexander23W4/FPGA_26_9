#!/usr/bin/env bash
# =============================================================================
#  build_incr.sh —— 省时间的增量综合/实现 (只重跑受影响的部分)
#
#  用法:
#      ./scripts/build_incr.sh                      # 默认 fpga_26, jobs=8
#      ./scripts/build_incr.sh fpga_26 12           # 12 个线程
#      JOBS=16 ./scripts/build_incr.sh
#
#  和 ./scripts/build.sh zynq -n fpga_26 -H 的区别:
#      build.sh        : reset_run synth_1 => PL 侧全量重综合   (15~25 min)
#      build_incr.sh   : 不 reset + 综合/实现都开增量           (5~12 min)
#
#  ★ 什么时候不要用它:
#      改了 Block Design 结构 / 改了 XDC 约束 / 增量后时序不收敛
#      => 退回:  ./scripts/build.sh zynq -n fpga_26 -H
# =============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-fpga_26}"
JOBS="${JOBS:-${2:-8}}"

VIVADO="${VIVADO:-/e/Xilinx/Vivado/2023.2/bin/vivado.bat}"
XPR="$ROOT/build/vivado/$NAME/$NAME.xpr"
TCL="$ROOT/scripts/tcl/incr_build.tcl"

if [[ ! -f "$VIVADO" ]]; then
    echo "[build_incr] 找不到 Vivado: $VIVADO" >&2
    echo "            可以用 VIVADO=/path/to/vivado.bat 指定" >&2
    exit 1
fi
if [[ ! -f "$XPR" ]]; then
    echo "[build_incr] 找不到工程: $XPR" >&2
    echo "            先用普通流程建一次工程(带 -R), 之后再走增量" >&2
    exit 1
fi
if [[ ! -f "$TCL" ]]; then
    echo "[build_incr] 找不到 $TCL" >&2
    exit 1
fi

echo "==============================================================="
echo " 增量综合/实现"
echo "   工程 : $XPR"
echo "   线程 : $JOBS"
echo "   脚本 : $TCL"
echo "==============================================================="

# 如果已经有一个 vivado 在跑同一个工程, 会互相锁死, 这里先提醒一下
if command -v tasklist >/dev/null 2>&1; then
    if tasklist 2>/dev/null | grep -qi "vivado.exe"; then
        echo "[build_incr] ⚠ 检测到已有 vivado.exe 在运行"
        echo "            同一个工程被两个 Vivado 打开会锁冲突, 建议先关掉 GUI"
        echo "            (继续跑也可以, 5 秒后开始)"
        sleep 5
    fi
fi

# ★ 注意顺序: -tclargs 会吃掉它后面的所有参数, 所以别的 flag 必须写在它前面
exec "$VIVADO" -mode batch -notrace -nojournal \
    -source "$(cygpath -w "$TCL")" \
    -tclargs "$(cygpath -w "$XPR")" "$JOBS"
