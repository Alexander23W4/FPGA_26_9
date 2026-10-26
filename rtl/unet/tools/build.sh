#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
export FPGA_26_9_ROOT="$(cygpath -m "$PWD")"
hls="${UNET_HLS_BIN:-/e/Xilinx/Vitis_HLS/2023.2/bin/vitis_hls.bat}"
python rtl/unet/tools/export_small_model.py
"$hls" -f "$(cygpath -w rtl/unet/small_hls/build_hls.tcl)"
"$hls" -f "$(cygpath -w rtl/inter_fr/ddr/build_hls.tcl)"
python rtl/unet/tools/freshness.py --check
echo 'UNET_HARDWARE_GENERATED'
