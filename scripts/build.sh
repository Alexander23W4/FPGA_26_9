#!/usr/bin/env bash
# =============================================================================
#  build.sh —— ACZ7015 工程构建入口（唯一入口）
# =============================================================================
#
#  命令:
#      check     Environment self-check
#      pl        Pure PL flow: create project -> synth -> impl -> bitstream
#      zynq      Zynq flow: create project(+BD) -> bitstream -> export .xsa
#      app       PS app: .xsa -> platform -> application -> .elf   (via xsct)
#      all       zynq + app
#      sim       Run simulation
#      export    Export GUI-made project changes back to Tcl
#      clean     Remove everything under build/
#
#  选项:
#      -n, --name NAME      Project name (required for most commands)
#      -a, --axi            Add AXI infra + LED GPIO when creating Zynq project
#      -t, --top TOP        Top module name for pure-PL project
#      -b, --tb TB          Testbench top name for simulation
#      -j, --jobs N         Parallel jobs for synth/impl (default 4)
#      -h, --help           Show help
#
#  示例:
#      ./scripts/build.sh check
#      ./scripts/build.sh pl   -n led_demo -t led_top
#      ./scripts/build.sh zynq -n zynq_led -a
#      ./scripts/build.sh all  -n zynq_led -a
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ------------------------------ 帮助（英文输出）------------------------------
usage() {
  cat <<'EOF'
ACZ7015 build entry

Usage:
  ./scripts/build.sh <command> [options]

Commands:
  check                 Environment self-check
  pl                    Pure PL:    create project -> synth -> impl -> bitstream
  zynq                  Zynq:       create project(+BD) -> bitstream -> .xsa
  app                   PS app:     .xsa -> platform -> application -> .elf (xsct)
  all                   zynq + app
  sim                   Run simulation
  export                Export GUI-made project changes back to Tcl
  clean                 Remove everything under build/

Options:
  -n, --name NAME       Project name (required)
  -a, --axi             Add AXI infrastructure + LED GPIO (Zynq only)
  -t, --top TOP         Top module name (pure PL)
  -b, --tb TB           Testbench top name (sim)
  -j, --jobs N          Parallel jobs for synth/impl (default 4)
  -h, --help            Show this help

Examples:
  ./scripts/build.sh check
  ./scripts/build.sh pl   -n led_demo -t led_top
  ./scripts/build.sh zynq -n zynq_led -a
  ./scripts/build.sh sim  -n led_demo -b tb_led_top

Environment overrides:
  XILINX_ROOT   default /e/Xilinx        e.g. XILINX_ROOT=/d/Xilinx
  VIVADO_VER    default 2023.2

Outputs are archived under:
  build/out/<YYYY-MM-DD_HHMMSS>_<gitshort>[ -dirty]/
EOF
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
    *) die "Unknown option: $1   (run with -h for help)" ;;
  esac
done

if [ -z "$CMD" ]; then usage; exit 1; fi

# =============================================================================
#  check
# =============================================================================
do_check() {
  exec "${SCRIPTS_DIR}/env_check.sh"
}

# =============================================================================
#  pl —— 纯 PL 全流程
# =============================================================================
do_pl() {
  [ -n "$NAME" ] || die "Missing -n <project name>"
  check_tools

  local out; out="$(new_out_dir)"
  info "Archive dir: ${out#${REPO_ROOT}/}"

  run_vivado "${SCRIPTS_DIR}/tcl/build_pl.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$TOP" "$JOBS" 2>&1 | tee "${out}/build.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "Vivado build failed (rc=$rc). Log: ${out}/build.log"

  local pdir="${VIVADO_PROJ_DIR}/${NAME}"
  local bit; bit="$(find "$pdir" -name '*.bit' -print -quit 2>/dev/null)"
  if [ -n "$bit" ]; then
    cp -f "$bit" "$out/" 2>/dev/null || cp -f "$(winpath "$bit")" "$out/"
    ok "Bitstream: $(basename "$bit")"
  else
    warn "No .bit file produced"
  fi

  local ltx; ltx="$(find "$pdir" -name '*.ltx' -print -quit 2>/dev/null)"
  [ -n "$ltx" ] && cp -f "$ltx" "$out/" && ok "Probe file: $(basename "$ltx")"

  write_manifest "$out" "$NAME" "pl"
  hr; ok "PL build done -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  zynq —— Zynq 全流程（位流 + xsa）
# =============================================================================
do_zynq() {
  [ -n "$NAME" ] || die "Missing -n <project name>"
  check_tools

  local out; out="$(new_out_dir)"
  info "Archive dir: ${out#${REPO_ROOT}/}"

  local axiflag=""
  [ "$AXI" -eq 1 ] && axiflag="-axi"

  run_vivado "${SCRIPTS_DIR}/tcl/build_zynq.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$axiflag" "$JOBS" 2>&1 | tee "${out}/build.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "Vivado build failed (rc=$rc). Log: ${out}/build.log"

  local pdir="${VIVADO_PROJ_DIR}/${NAME}"
  local bit xsa
  bit="$(find "$pdir" -name '*.bit' -print -quit 2>/dev/null)"
  xsa="$(find "$pdir" -name '*.xsa' -print -quit 2>/dev/null)"

  if [ -n "$bit" ]; then cp -f "$bit" "$out/" && ok "Bitstream: $(basename "$bit")"; else warn "No .bit"; fi
  if [ -n "$xsa" ]; then cp -f "$xsa" "$out/" && ok "Hardware platform: $(basename "$xsa")"; else warn "No .xsa"; fi

  write_manifest "$out" "$NAME" "zynq"
  hr; ok "Zynq build done -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  app —— PS 端应用（xsct）
# =============================================================================
do_app() {
  [ -n "$NAME" ] || die "Missing -n <application name>"
  [ -f "$XSCT_BIN" ] || die "xsct not found: $XSCT_BIN"

  # 找最新的 .xsa
  local xsa
  xsa="$(find "${OUT_DIR}" -name '*.xsa' -print 2>/dev/null | sort | tail -n1)"
  [ -n "$xsa" ] || die "No .xsa under build/out/. Run first: ./scripts/build.sh zynq -n <project>"

  local out; out="$(new_out_dir)"
  info "Using hardware platform: ${xsa#${REPO_ROOT}/}"

  mkdir -p "${VITIS_WS_DIR}"
  run_xsct "${SCRIPTS_DIR}/xsct/build_app.tcl" \
      "$NAME" "$(winpath "$xsa")" "$(winpath "${VITIS_WS_DIR}")" 2>&1 | tee "${out}/build.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "xsct build failed (rc=$rc)"

  local elf
  elf="$(find "${VITIS_WS_DIR}" -name '*.elf' -print 2>/dev/null | head -n1)"
  if [ -n "$elf" ]; then cp -f "$elf" "$out/" && ok "ELF: $(basename "$elf")"; else warn "No .elf"; fi

  write_manifest "$out" "$NAME" "app"
  hr; ok "PS app build done -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  all
# =============================================================================
do_all() {
  [ -n "$NAME" ] || die "Missing -n <project name>"
  do_zynq
  do_app
}

# =============================================================================
#  sim
# =============================================================================
do_sim() {
  [ -n "$NAME" ] || die "Missing -n <project name>"
  check_tools

  local out; out="$(new_out_dir)"
  run_vivado "${SCRIPTS_DIR}/tcl/run_sim.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$TB" 2>&1 | tee "${out}/sim.log"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || die "Simulation failed (rc=$rc). Log: ${out}/sim.log"

  write_manifest "$out" "$NAME" "sim"
  hr; ok "Simulation done -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  export
# =============================================================================
do_export() {
  [ -n "$NAME" ] || die "Missing -n <project name>"
  check_tools
  run_vivado "${SCRIPTS_DIR}/tcl/export_project.tcl" \
      "$NAME" "$(winpath "${VIVADO_PROJ_DIR}")" "$(winpath "${SCRIPTS_DIR}/exported")"
  ok "Exported Tcl is under scripts/exported/ -- commit them"
}

# =============================================================================
#  clean
# =============================================================================
do_clean() {
  info "Cleaning ${BUILD_DIR#${REPO_ROOT}/} ..."
  # 保留 build/.gitkeep
  find "$BUILD_DIR" -mindepth 1 -not -name '.gitkeep' -exec rm -rf {} + 2>/dev/null
  mkdir -p "$VIVADO_PROJ_DIR" "$VITIS_WS_DIR" "$OUT_DIR"
  ok "Clean done"
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
  *) die "Unknown command: $CMD   (run with -h for help)" ;;
esac
