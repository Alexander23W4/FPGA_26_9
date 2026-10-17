#!/usr/bin/env bash
# =============================================================================
#  build.sh —— ACZ7015 工程构建入口（唯一入口）
# =============================================================================
#
#  命令:
#      check     Environment self-check
#      pl        Pure PL flow: create project -> synth -> impl -> bitstream
#      zynq      Zynq flow: create project(+BD) -> bitstream -> export .xsa
#      app       PS app: .xsa -> platform -> application -> .elf   (via Vitis Unified)
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
  app                   PS app:     .xsa -> platform -> application -> .elf (Vitis Unified)
  all                   zynq + app
  sim                   Run simulation
  export                Export GUI-made project changes back to Tcl
  clean                 Remove everything under build/

Options:
  -n, --name NAME       Project name / application name (required)
  -a, --axi             Add AXI infrastructure + LED GPIO (Zynq only)
  -H, --hp              Add the PL-master-reads-DDR path (Zynq only):
                        enables PS S_AXI_HP0, adds config/status GPIOs, and
                        exposes S_AXI_IMG + FCLK_CLK0 + peripheral_aresetn
      --fclk0 MHZ       FCLK_CLK0 frequency for the Zynq design (default 50)
  -R, --recreate        Delete the Vivado project first and rebuild it from Tcl
                        (required after any Block Design change)
  -t, --top TOP         Top module name (pure PL)
  -b, --tb TB           Testbench top name (sim)
  -j, --jobs N          Parallel jobs for synth/impl (default 4)
  -T, --template NAME   Vitis application template for "app" (default hello_world)
                        hello_world ships its own source, so the build produces an
                        ELF right away; use empty_application for a blank src/
      --no-fs           Do not add the xilffs (FatFs) library to the BSP.
                        By default the BSP gets xilffs so that the PS can read
                        files from the SD card. File names must be 8.3
                        (e.g. CT0001.BIN) because long file names are not
                        usable in this Vitis version.
  -p, --platform NAME   Platform component name for "app"/"all"
                        (default: the hardware project name, i.e. the .xsa file
                         name, with NO suffix. It must differ from the
                         application name, otherwise the command fails.
                         Required for "all".)
  -f, --force-platform  Force rebuilding the platform even if already built
      --xsa FILE       Use this exact hardware platform for the PS build
  -h, --help            Show this help

Examples:
  ./scripts/build.sh check
  ./scripts/build.sh pl   -n led_demo -t led_top
  ./scripts/build.sh zynq -n zynq_led -a
  ./scripts/build.sh app  -n hello
  ./scripts/build.sh sim  -n led_demo -b tb_led_top

Environment overrides:
  XILINX_ROOT   default /e/Xilinx        e.g. XILINX_ROOT=/d/Xilinx
  VIVADO_VER    default 2023.2
  PL_CLK_MHZ    default 80             processing/AXI only; HDMI stays 25.2/126 MHz

Outputs are archived under:
  build/out/<YYYY-MM-DD_HHMMSS>_<gitshort>[ -dirty]/
EOF
}

# ---------------------------- 参数解析 --------------------------------------
CMD="${1:-}"; shift || true

NAME=""; AXI=0; TOP=""; TB=""; JOBS=4; PLATFORM=""; FORCE_PLATFORM=0; TEMPLATE="hello_world"
HP=0; FCLK0=""; RECREATE=0; NO_FS=0; XSA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name) NAME="${2:-}"; shift 2 ;;
    -a|--axi)  AXI=1; shift ;;
    -H|--hp)   HP=1; shift ;;
    --fclk0)   FCLK0="${2:-}"; shift 2 ;;
    -R|--recreate) RECREATE=1; shift ;;
    --no-fs)   NO_FS=1; shift ;;
    -t|--top)  TOP="${2:-}";  shift 2 ;;
    -b|--tb)   TB="${2:-}";   shift 2 ;;
    -j|--jobs) JOBS="${2:-4}"; shift 2 ;;
    -T|--template) TEMPLATE="${2:-}"; shift 2 ;;
    -p|--platform)       PLATFORM="${2:-}"; shift 2 ;;
    -f|--force-platform) FORCE_PLATFORM=1; shift ;;
    --xsa) XSA="${2:-}"; shift 2 ;;
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

# -----------------------------------------------------------------------------
#  平台名 / 应用名 校验
#  平台组件和应用组件在 Vitis 工作区里是同一层的目录，同名会互相覆盖。
#  这里不做任何自动改名，直接让命令失败。
#  用法: check_component_names <应用名> <平台名>
# -----------------------------------------------------------------------------
check_component_names() {
  local app="$1"
  local plat="$2"

  if [ "$plat" = "$app" ]; then
    err "Platform name and application name are identical: ${app}"
    err "They would occupy the same directory under ${VITIS_WS_DIR#${REPO_ROOT}/}/"
    err ""
    err "The platform defaults to the hardware project name, so this happens when"
    err "the application is named after the hardware project."
    err ""
    err "Pick one:"
    err "  * give the platform its own name:   -p <platform_name>"
    err "  * give the application another name: -n <app_name>"
    err ""
    err "Example: ./scripts/build.sh app -n ${app} -p <platform_name>"
    die "Refusing to run with colliding component names."
  fi
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
      mkdir -p "${out}" || { echo "[FAIL] cannot create ${out}"; exit 1; }
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
  rm -f "${OUT_DIR}/latest-${NAME}-zynq.path" "${OUT_DIR}/latest-zynq.path"

  # -R：先删掉 Vivado 工程，强制从 Tcl 重建（改了 BD 结构时必须）
  if [ "$RECREATE" -eq 1 ]; then
    info "Recreating project: removing ${VIVADO_PROJ_DIR}/${NAME}"
    rm -rf "${VIVADO_PROJ_DIR:?}/${NAME:?}"
  fi

  local out; out="$(new_out_dir)"
  info "Archive dir: ${out#${REPO_ROOT}/}"
  info "Checking PL input files ..."
  pl_input_hashes > "$out/PL_INPUTS.sha256" || die "Cannot snapshot PL inputs"
  info "PL input check done. Starting Vivado; log: ${out#${REPO_ROOT}/}/build.log"

  # 组装透传给 build_zynq.tcl 的选项
  local vargs=("$NAME" "$(winpath "${VIVADO_PROJ_DIR}")")
  [ "$AXI" -eq 1 ] && vargs+=("-axi")
  [ "$HP"  -eq 1 ] && vargs+=("-hp")
  [ -n "$FCLK0" ]  && vargs+=("-fclk0" "$FCLK0")
  vargs+=("$JOBS")

  mkdir -p "${out}" || { echo "[FAIL] cannot create ${out}"; exit 1; }
  run_vivado "${SCRIPTS_DIR}/tcl/build_zynq.tcl" "${vargs[@]}" 2>&1 | /usr/bin/tee "${out}/build.log"
  local rc="$?"
  [ "$rc" -eq 0 ] && grep -q '^BUILD_ZYNQ_OK[[:space:]]*$' "$out/build.log" \
    || die "Vivado build did not finish successfully (rc=$rc). Log: ${out}/build.log"
  (cd "$REPO_ROOT" && sha256sum -c "$out/PL_INPUTS.sha256" >/dev/null) \
    || die "PL inputs changed during the build; rebuild before downloading"

  local pdir="${VIVADO_PROJ_DIR}/${NAME}"
  local bit xsa
  bit="${pdir}/${NAME}.runs/impl_1/system_wrapper.bit"
  xsa="${pdir}/${NAME}.xsa"
  [ -s "$bit" ] && [ -s "$xsa" ] || die "Missing current bitstream or XSA"
  cp -f "$bit" "$xsa" "$out/" || die "Cannot archive hardware outputs"
  if [ "$NAME" = fpga_26 ]; then
    grep -q '^PL_REGISTERS_OK ' "$out/build.log" || die "Missing implemented-register check"
    cp -f "$pdir/register_audit.txt" "$out/" || die "Missing register audit report"
  fi
  (cd "$out" && sha256sum system_wrapper.bit "${NAME}.xsa" > ARTIFACTS.sha256) \
    || die "Cannot hash hardware outputs"

  write_manifest "$out" "$NAME" "zynq" || die "Cannot write hardware manifest"
  publish_build "$out" "$NAME" zynq || die "Cannot publish hardware build"
  hr; ok "Zynq build done -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  app —— PS 端应用（Vitis Unified，vitis -s）
# =============================================================================
do_app() {
  [ -n "$NAME" ] || die "Missing -n <application name>"
  [ -f "$VITIS_BIN" ] || die "Vitis not found: $VITIS_BIN"

  # Use an explicit XSA or a successful build receipt, never a directory sort.
  local xsa hwout receipt
  if [ -n "$XSA" ]; then
    xsa="$XSA"
  else
    receipt="${OUT_DIR}/latest-zynq.path"
    [ -z "$PLATFORM" ] || receipt="${OUT_DIR}/latest-${PLATFORM}-zynq.path"
    [ -s "$receipt" ] || die "No successful hardware build receipt. Build zynq first or pass --xsa FILE"
    hwout="$(cat "$receipt")"
    [ -z "$PLATFORM" ] && PLATFORM="$(sed -n 's/^project     : //p' "$hwout/MANIFEST.txt")"
    xsa="$hwout/${PLATFORM}.xsa"
    (cd "$hwout" && sha256sum -c ARTIFACTS.sha256 >/dev/null) || die "Hardware archive is incomplete or modified"
  fi
  [ -s "$xsa" ] || die "Hardware platform not found: $xsa"

  # 平台名默认 = 硬件工程名（就是 xsa 的文件名），不加任何后缀
  if [ -z "$PLATFORM" ]; then
    PLATFORM="$(basename "$xsa" .xsa)"
    info "Platform name not given, using hardware project name: ${PLATFORM}"
  fi
  check_component_names "$NAME" "$PLATFORM"
  rm -f "${OUT_DIR}/latest-${NAME}-app.path"

  local out; out="$(new_out_dir)"
  info "Using hardware platform: ${xsa#${REPO_ROOT}/}"
  info "Checking PS source files ..."
  ps_input_hashes "$NAME" user > "$out/PS_USER_INPUTS.sha256" || die "Cannot snapshot PS sources"
  info "PS source check done. Starting Vitis; log: ${out#${REPO_ROOT}/}/build.log"

  mkdir -p "${VITIS_WS_DIR}"
  # 组装参数：平台名 + 模板 + --force-platform（选填）
  local vargs=("$NAME" "$(winpath "$xsa")" "$(winpath "${VITIS_WS_DIR}")" "$PLATFORM"
               "--template" "$TEMPLATE")
  [ "$FORCE_PLATFORM" -eq 1 ] && vargs+=("--force-platform")
  [ "$NO_FS" -eq 1 ] && vargs+=("--no-fs")

  mkdir -p "${out}" || { echo "[FAIL] cannot create ${out}"; exit 1; }
  run_vitis "${SCRIPTS_DIR}/vitis/build_ps.py" "${vargs[@]}" 2>&1 | /usr/bin/tee "${out}/build.log"
  local rc="$?"

  # ⚠ vitis.bat 不传递 python 的退出码，所以必须查日志里的错误标记
  if [ "$rc" -ne 0 ] \
     || ! grep -q '^BUILD_PS_OK[[:space:]]*$' "$out/build.log" \
     || grep -qE '^!!!|Traceback \(most recent call last\)|BUILD_FAILED|PLATFORM_FAILED|APP_FAILED|NOXPFM|NOXSA' "${out}/build.log"; then
    die "Vitis build failed. Log: ${out}/build.log"
  fi

  # 只在应用组件目录里找 elf，避免误抓 platform 的 fsbl.elf
  local elf
  elf="${VITIS_WS_DIR}/${NAME}/build/${NAME}.elf"
  [ -s "$elf" ] || die "No ELF produced for this application: $elf"
  if [ -s "$out/PS_USER_INPUTS.sha256" ]; then
    (cd "$REPO_ROOT" && sha256sum -c "$out/PS_USER_INPUTS.sha256") \
      || die "PS user sources changed during the build; see FAILED file above"
  fi
  # Record the final generated build configuration as well. A later manual
  # change to CMakeLists.txt still prevents downloading this ELF.
  ps_input_hashes "$NAME" > "$out/PS_INPUTS.sha256" || die "Cannot snapshot final PS inputs"
  local init="${VITIS_WS_DIR}/${PLATFORM}/hw/sdt/ps7_init.tcl"
  [ -s "$init" ] || die "No PS initialization script in the selected platform: $init"
  cp -f "$elf" "$init" "$out/" || die "Cannot archive PS outputs"
  sha256sum "$xsa" | cut -d' ' -f1 > "$out/XSA.sha256" || die "Cannot hash the selected XSA"
  (cd "$out" && sha256sum "${NAME}.elf" ps7_init.tcl > ARTIFACTS.sha256) \
    || die "Cannot hash PS outputs"

  write_manifest "$out" "$NAME" "app" || die "Cannot write application manifest"
  publish_build "$out" "$NAME" app || die "Cannot publish application build"
  hr; ok "PS app build done -> ${out#${REPO_ROOT}/}"; hr
}

# =============================================================================
#  all
# =============================================================================
do_all() {
  [ -n "$NAME" ] || die "Missing -n <project name>"
  # 这里 -n 同时是工程名和应用名，平台名默认就是工程名 -> 必然相撞。
  # 所以在最前面就拦下来，别等 Vivado 跑完才报错。
  [ -n "$PLATFORM" ] || die "\"all\" needs -p <platform_name>: -n is used for both the project and the application, so the default platform name (= project name) would collide"
  check_component_names "$NAME" "$PLATFORM"
  do_zynq
  XSA="$(cat "${OUT_DIR}/latest-${NAME}-zynq.path")/${NAME}.xsa"
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
      mkdir -p "${out}" || { echo "[FAIL] cannot create ${out}"; exit 1; }
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
