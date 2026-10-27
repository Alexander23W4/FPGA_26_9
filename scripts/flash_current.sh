#!/usr/bin/env bash
# Download the verified hardware/app archives published by build.sh.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"
mode="${1:-init}"
[[ "$mode" == init || "$mode" == noinit ]] || die "Usage: bash scripts/flash_current.sh [init|noinit]"
for target in fpga_26-zynq MID_plt-app; do
  [ -s "$OUT_DIR/latest-${target}.path" ] || die "No successful $target build; run build.sh first"
done
hwout="$(cat "$OUT_DIR/latest-fpga_26-zynq.path")"
psout="$(cat "$OUT_DIR/latest-MID_plt-app.path")"
(cd "$hwout" && sha256sum -c ARTIFACTS.sha256) || die "Hardware output changed"
(cd "$psout" && sha256sum -c ARTIFACTS.sha256) || die "PS output changed"
sha256sum -c "$hwout/PL_INPUTS.sha256" >/dev/null || die "PL inputs changed; rebuild zynq"
sha256sum -c "$psout/PS_INPUTS.sha256" >/dev/null || die "PS sources changed; rebuild app"
[ "$(sha256sum "$hwout/fpga_26.xsa" | cut -d' ' -f1)" = "$(cat "$psout/XSA.sha256")" ] \
  || die "ELF platform differs from this XSA; rebuild app -p fpga_26 -f"
[ -s "$hwout/register_audit.txt" ] || die "Missing PL register verification"
info "Verified bitstream: $hwout/system_wrapper.bit"
info "Verified ELF: $psout/MID_plt.elf"
# The PL U-Net keeps its parameters in DDR, so every cold GUI session must
# reload the model after PS/DDR initialisation.  Honour an explicit override,
# otherwise use this checkout's deployed model image when present.
if [[ -z "${UNET_WEIGHTS:-}" && -s "$REPO_ROOT/build/unet/model/weights.bin" ]]; then
  UNET_WEIGHTS="$(winpath "$REPO_ROOT/build/unet/model/weights.bin")"
  export UNET_WEIGHTS
fi
# Some Windows XSCT failures (including Tcl/native shutdown errors) return zero.
# Require the final Tcl success marker as well as the process/pipeline status.
# Keep diagnostics outside build/out so successful build archives stay immutable.
mkdir -p "$BUILD_DIR/flash"
flash_log="$(mktemp "$BUILD_DIR/flash/flash-$(date +%Y-%m-%d_%H%M%S)-XXXXXX.log")"
info "Flash log: $flash_log"
if "$XSCT_BIN" "$(winpath "$SCRIPTS_DIR/tcl/flash_all.tcl")" \
    "$(winpath "$hwout/system_wrapper.bit")" "$(winpath "$psout/MID_plt.elf")" \
    "$(winpath "$psout/ps7_init.tcl")" "$mode" 2>&1 | /usr/bin/tee "$flash_log"; then
  /usr/bin/tr -d '\r' < "$flash_log" | /usr/bin/grep -Fxq 'FLASH_ALL_OK' \
    || die "XSCT did not confirm successful programming; GUI will not start. Log: $flash_log"
else
  die "XSCT programming failed; GUI will not start. Log: $flash_log"
fi
ok "Programming completed and confirmed"
