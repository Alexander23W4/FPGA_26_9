#!/usr/bin/env bash
# =============================================================================
#  build.sh —— ACZ7015 工程构建入口（唯一入口）
# =============================================================================
#  用法:
#      ./scripts/build.sh <命令> [选项]
#
#  命令:
#      check                环境自检
#      pl                   纯 PL 工程: 建工程 -> 综合 -> 实现 -> 生成位流
#      zynq                 Zynq 工程: 建工程(+BD) -> 位流 -> 导出 .xsa
#      app                  PS 端: .xsa -> platform -> application -> .elf
#      all                  zynq + app 全流程
#      sim                  仿真
#      export               把 GUI 里改过的工程导回 Tcl（便于提交）
#      clean                清理 build/ 下所有生成物
#
#  选项:
#      -n, --name NAME      工程名（pl/zynq/app/sim 必需）
#      -a, --axi            建 Zynq 工程时带 AXI 基础设施 + LED GPIO
#      -t, --top TOP        纯 PL 工程顶层模块名
#      -b, --tb TB          仿真顶层测试平台名
#      -j, --jobs N         综合/实现并行数（默认 4）
#      -k, --keep           保留中间产物（默认也保留，供增量）
#      -h, --help           帮助
#
#  例:
#      ./scripts/build.sh check
#      ./scripts/build.sh pl   -n led_demo -t led_flash
#      ./scripts/build.sh zynq -n zynq_led -a
#      ./scripts/build.sh all  -n zynq_led -a
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ------------------------------ 帮助 ----------------------------------------
usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------- 参数解析 --------------------------------------
CMD="${1:-}"; shift || true

NAME=""; AXI=0; TOP=""; TB=""; JOBS=4
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name) NAME="${2:-}"; shift 2 ;;
    -a|--axi)  AXI=1; shift ;;
    -t|--top)  TOP="${2:-}";  shift 2 ;;
    -b|--tb)   TB="${2:-}";   shift 2 ;;
    -j|--jobs) JOBS="${2:-4}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项: $1   （用 -h 看帮助）" ;;
  esac
done

[ -n "$CMD" ] || { usage; exit 1; }

# =============================================================================
#  check —— 环境自检
# =============================================================================
do_check() {
  exec "${SCRIPTS_DIR}/env_check.sh"
}

# =============================================================================
#  pl —— 纯 PL 全流程
# =============================================================================
do_pl() {
  [ -n "$NAME" ] || die "缺少 -n <工程名>"
  check_tools

  local out; out="$(new_out_dir)"
  info "产物将归档到: ${out#${REPO_ROOT}/}"

  run_vivado "${SCRIPTS_DIR}/tcl/build_pl.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$TOP" "$JOBS" 2>&1 | tee "${out}/build.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "Vivado 构建失败（rc=$rc），日志: ${out}/build.log"

  # 收集产物
  local pdir="${VIVADO_PROJ_DIR}/${NAME}"
  local bit; bit="$(find "$pdir" -name '*.bit' -print -quit 2>/dev/null)"
  if [ -n "$bit" ]; then
    cp -f "$(winpath "$bit")" "$out/" 2>/dev/null || cp -f "$bit" "$out/"
    ok "位流: $(basename "$bit")"
  else
    warn "未找到 .bit 文件"
  fi

  local ltx; ltx="$(find "$pdir" -name '*.ltx' -print -quit 2>/dev/null)"
  [ -n "$ltx" ] && cp -f "$ltx" "$out/" && ok "探针文件: $(basename "$ltx")"

  write_manifest "$out" "$NAME" "pl"
  hr; ok "PL 构建完成 -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  zynq —— Zynq 全流程（位流 + xsa）
# =============================================================================
do_zynq() {
  [ -n "$NAME" ] || die "缺少 -n <工程名>"
  check_tools

  local out; out="$(new_out_dir)"
  info "产物将归档到: ${out#${REPO_ROOT}/}"

  local axiflag=""
  [ "$AXI" -eq 1 ] && axiflag="-axi"

  run_vivado "${SCRIPTS_DIR}/tcl/build_zynq.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$axiflag" "$JOBS" 2>&1 | tee "${out}/build.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "Vivado 构建失败（rc=$rc），日志: ${out}/build.log"

  local pdir="${VIVADO_PROJ_DIR}/${NAME}"
  local bit xsa
  bit="$(find "$pdir" -name '*.bit' -print -quit 2>/dev/null)"
  xsa="$(find "$pdir" -name '*.xsa' -print -quit 2>/dev/null)"

  [ -n "$bit" ] && cp -f "$bit" "$out/" && ok "位流: $(basename "$bit")" || warn "未找到 .bit"
  [ -n "$xsa" ] && cp -f "$xsa" "$out/" && ok "硬件平台: $(basename "$xsa")" || warn "未找到 .xsa"

  write_manifest "$out" "$NAME" "zynq"
  hr; ok "Zynq 构建完成 -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  app —— PS 端应用（xsct 脚本化）
# =============================================================================
do_app() {
  [ -n "$NAME" ] || die "缺少 -n <应用名>"
  [ -f "$XSCT_BIN" ] || die "找不到 xsct: $XSCT_BIN"

  # 找最新的 .xsa
  local xsa
  xsa="$(find "${OUT_DIR}" -name '*.xsa' -print 2>/dev/null | sort | tail -n1)"
  [ -n "$xsa" ] || die "在 build/out/ 下找不到 .xsa，请先跑: ./scripts/build.sh zynq -n <工程名>"

  local out; out="$(new_out_dir)"
  info "使用硬件平台: ${xsa#${REPO_ROOT}/}"

  mkdir -p "${VITIS_WS_DIR}"
  run_xsct "${SCRIPTS_DIR}/xsct/build_app.tcl" \
      "$NAME" "$(winpath "$xsa")" "$(winpath "${VITIS_WS_DIR}")" 2>&1 | tee "${out}/build.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "xsct 构建失败（rc=$rc）"

  local elf
  elf="$(find "${VITIS_WS_DIR}" -name '*.elf' -print 2>/dev/null | head -n1)"
  [ -n "$elf" ] && cp -f "$elf" "$out/" && ok "ELF: $(basename "$elf")" || warn "未找到 .elf"

  write_manifest "$out" "$NAME" "app"
  hr; ok "PS 应用构建完成 -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  all —— PL + PS 全流程
# =============================================================================
do_all() {
  [ -n "$NAME" ] || die "缺少 -n <工程名>"
  do_zynq
  do_app
}

# =============================================================================
#  sim —— 仿真
# =============================================================================
do_sim() {
  [ -n "$NAME" ] || die "缺少 -n <工程名>（用于定位/建立仿真工程）"
  check_tools

  local out; out="$(new_out_dir)"
  run_vivado "${SCRIPTS_DIR}/tcl/run_sim.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$TB" 2>&1 | tee "${out}/sim.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "仿真失败（rc=$rc），日志: ${out}/sim.log"

  cp -f "${out}/sim.log" "$out/" 2>/dev/null || true
  write_manifest "$out" "$NAME" "sim"
  hr; ok "仿真完成 -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  export —— 把 GUI 里改过的工程导回 Tcl
# =============================================================================
do_export() {
  [ -n "$NAME" ] || die "缺少 -n <工程名>"
  check_tools
  run_vivado "${SCRIPTS_DIR}/tcl/export_project.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$(winpath "${SCRIPTS_DIR}/exported")"
  ok "导出的 Tcl 在 scripts/exported/ ，请提交它们"
}

# =============================================================================
#  clean
# =============================================================================
do_clean() {
  info "清理 ${BUILD_DIR#${REPO_ROOT}/} ..."
  # 保留 build/.gitkeep
  find "$BUILD_DIR" -mindepth 1 -not -name '.gitkeep' -exec rm -rf {} + 2>/dev/null
  mkdir -p "$VIVADO_PROJ_DIR" "$VITIS_WS_DIR" "$OUT_DIR"
  ok "已清理"
}

# =============================================================================
case "$CMD" in
  check)  do_check ;;
  pl)     do_pl ;;
  zynq)   do_zynq ;;
  app)    do_app ;;
  all)    do_all ;;
  sim)    do_sim ;;
  export) do_export ;;
  clean)  do_clean ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) die "未知命令: $CMD   （用 -h 看帮助）" ;;
esac
