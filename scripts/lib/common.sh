#!/usr/bin/env bash
# =============================================================================
#  lib/common.sh —— 公共函数库（由 build.sh / env_check.sh source）
# =============================================================================
#  ⚠ 本文件必须使用 LF 换行。若变成 CRLF，Git Bash 会报
#     "$'\r': command not found"。修复：dos2unix scripts/**/*.sh
# =============================================================================

# ------------------------------- 路径 ---------------------------------------
set -o pipefail
# Vitis settings prepend an old gnuwin directory to PATH. Its tee.exe fails
# on Git Bash/MSYS stdout pipes. Use one MSYS tool set for shell operations;
# Vivado, Vitis and XSCT themselves are invoked by explicit .bat paths below.
export PATH="/usr/bin:/mingw64/bin:$PATH"
hash -r
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${_lib_dir}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build"
VIVADO_PROJ_DIR="${BUILD_DIR}/vivado"
# ★ Vitis 工作区放在 csrc/，不放在 build/。
#   理由：应用组件的 src/ 就是【你的 C 源码】，必须能被 git 跟踪，
#         而且不能被 scripts/build.sh clean 删掉。
#   csrc/<组件名>/ 由脚本自动建（平台名 / 应用名）。
VITIS_WS_DIR="${REPO_ROOT}/csrc"
OUT_DIR="${BUILD_DIR}/out"

# ---------------------------- 工具链路径 -------------------------------------
# 可用环境变量覆盖，例如：XILINX_ROOT=/d/Xilinx ./scripts/build.sh check
XILINX_ROOT="${XILINX_ROOT:-/e/Xilinx}"
VIVADO_VER="${VIVADO_VER:-2023.2}"
VIVADO_BIN="${XILINX_ROOT}/Vivado/${VIVADO_VER}/bin/vivado.bat"
VITIS_BIN="${XILINX_ROOT}/Vitis/${VIVADO_VER}/bin/vitis.bat"
XSCT_BIN="${XILINX_ROOT}/Vitis/${VIVADO_VER}/bin/xsct.bat"

# ------------------------------- 板级常量 -----------------------------------
PART="xc7z015clg485-2"
BOARD_PART="xiaomeige.com:acz7015:part0:1.0"
BOARD_REPO="${REPO_ROOT}/board/acz7015/board_files"
XDC_FILE="${REPO_ROOT}/constrs/acz7015/acz7015.xdc"
PS7_PRESET="${REPO_ROOT}/board/acz7015/ps7_preset.tcl"

# ------------------------------- 颜色 ---------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_CYN=$'\033[36m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_DIM=''; C_RST=''
fi

info() { printf '%s[INFO]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*"; }
err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
hr()   { printf '%s%s%s\n' "$C_DIM" "============================================================" "$C_RST"; }

# --------------------------- Windows 路径转换 -------------------------------
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# ------------------------------ 调用 Vivado ---------------------------------
# 用法: run_vivado <tcl脚本> [tclargs...]
run_vivado() {
  local src="$1"; shift || true
  [ -f "$VIVADO_BIN" ] || die "找不到 Vivado: $VIVADO_BIN"
  local wsrc; wsrc="$(winpath "$src")"
  info "vivado <- $(basename "$src") ${*:+(args: $*)}"
  "$VIVADO_BIN" -mode batch -nolog -nojournal -source "$wsrc" -tclargs "$@"
}

# ------------------------------ 调用 Vitis ----------------------------------
# Unified IDE 的脚本接口是 `vitis -s <python>`（不是 xsct）
# 用法: run_vitis <python脚本> [args...]
run_vitis() {
  local src="$1"; shift || true
  [ -f "$VITIS_BIN" ] || die "找不到 Vitis: $VITIS_BIN"
  local wsrc; wsrc="$(winpath "$src")"
  info "vitis -s $(basename "$src") ${*:+(args: $*)}"
  "$VITIS_BIN" -s "$wsrc" "$@"
}

# ------------------------------- 版本信息 -----------------------------------
git_hash()  { git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "nogit"; }
git_dirty() { [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ] && printf -- '-dirty' || true; }
git_branch(){ git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-"; }

# ------------------------------ 归档目录 ------------------------------------
# 用法: OUT=$(new_out_dir)
new_out_dir() {
  mkdir -p "$OUT_DIR" || die "Cannot create $OUT_DIR"
  local d
  d="$(mktemp -d "${OUT_DIR}/$(date +%Y-%m-%d_%H%M%S)_$(git_hash)$(git_dirty)_XXXXXX")" \
    || die "Cannot create a unique archive directory"
  printf '%s' "$d"
}

# Relative paths let the download helper verify that inputs still match the
# successful build. Generated build/csrc platform files are not PL inputs.
pl_input_hashes() {
  (cd "$REPO_ROOT" && find rtl constrs board ip scripts/tcl -type f ! -path '*/__pycache__/*' ! -name '*.pyc' \
    -print0 | sort -z | xargs -0 sha256sum)
}

ps_input_hashes() {
  [ -d "$REPO_ROOT/csrc/$1/src" ] || return 0
  local generated="csrc/$1/src/CMakeLists.txt"
  # CMake emits this compilation database for editors; the build does not read
  # it as an input. Regeneration must not invalidate an otherwise current ELF.
  local compilation_db="csrc/$1/src/compile_commands.json"
  if [ "${2:-all}" = user ]; then
    # update_hw/app.build rewrite this root file. UserConfig.cmake, linker
    # scripts and C/H sources remain protected during the build.
    (cd "$REPO_ROOT" && find "csrc/$1/src" -type f ! -path "$generated" ! -path "$compilation_db" \
      -print0 | sort -z | xargs -0 -r sha256sum)
  else
    (cd "$REPO_ROOT" && find "csrc/$1/src" -type f ! -path "$compilation_db" \
      -print0 | sort -z | xargs -0 -r sha256sum)
  fi
}

publish_build() {
  local out="$1" name="$2" target="$3"
  printf '%s\n' "$out" > "${OUT_DIR}/latest-${name}-${target}.path.tmp" || return 1
  mv -f "${OUT_DIR}/latest-${name}-${target}.path.tmp" "${OUT_DIR}/latest-${name}-${target}.path" || return 1
  printf '%s\n' "$out" > "${OUT_DIR}/latest-${target}.path"
}

# ------------------------------ MANIFEST ------------------------------------
# 用法: write_manifest <目录> <工程名> <目标>
write_manifest() {
  local dir="$1" name="$2" target="$3"
  mkdir -p "$dir"
  {
    echo "# ACZ7015 build artifact manifest"
    echo "project     : $name"
    echo "target      : $target"
    echo "part        : $PART"
    echo "board_part  : $BOARD_PART"
    echo "vivado      : $VIVADO_VER"
    echo "git_hash    : $(git_hash)$(git_dirty)"
    echo "git_branch  : $(git_branch)"
    echo "built_at    : $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "host        : $(uname -s -r)"
    echo "repo_root   : $REPO_ROOT"
  } > "${dir}/MANIFEST.txt"
}

# ---------------------------- 依赖检查 --------------------------------------
require_cmds() {
  local miss=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
  [ -z "$miss" ] || die "缺少命令:$miss"
}

check_tools() {
  [ -f "$VIVADO_BIN" ] || die "找不到 Vivado: $VIVADO_BIN
    （可用 XILINX_ROOT / VIVADO_VER 环境变量覆盖）"
}
