#!/usr/bin/env bash
# Rebuild the current HDMI/VDMA debug PL image and program it with the existing PS ELF.
# Run from Git Bash: bash scripts/pc/rebuild_flash_debug.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

project="fpga_26"
jobs="${JOBS:-4}"
vivado_ver="${VIVADO_VER:-2023.2}"
xilinx_root="${XILINX_ROOT:-/e/Xilinx}"

# -R is required: the regenerated ILA probes and the AXI-Stream port metadata
# are part of the Block Design generated from Tcl.
./scripts/build.sh zynq -n "$project" -H -R --fclk0 50 -j "$jobs"

bit="build/vivado/${project}/${project}.runs/impl_1/system_wrapper.bit"
elf="csrc/MID_plt/build/MID_plt.elf"
ps7_init="csrc/${project}/hw/sdt/ps7_init.tcl"

for f in "$bit" "$elf" "$ps7_init"; do
  [[ -f "$f" ]] || { echo "missing required file: $f" >&2; exit 1; }
done

"${xilinx_root}/Vitis/${vivado_ver}/bin/xsct.bat" \
  "$(cygpath -w scripts/tcl/flash_all.tcl)" \
  "$(cygpath -w "$bit")" \
  "$(cygpath -w "$elf")" \
  "$(cygpath -w "$ps7_init")" init

