#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
export FPGA_26_9_ROOT="$(cygpath -m "$PWD")"
python rtl/unet/tools/export_model.py
hls="${UNET_HLS_BIN:-/e/Xilinx/Vitis_HLS/2023.2/bin/vitis_hls.bat}"
"$hls" -f "$(cygpath -w rtl/unet/hls/build_hls.tcl)"
"$hls" -f "$(cygpath -w rtl/inter_fr/ddr/build_hls.tcl)"
python rtl/unet/tools/freshness.py --check
echo 'UNET_HARDWARE_GENERATED'
