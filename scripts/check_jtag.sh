#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
"$XSCT_BIN" "$(winpath "$SCRIPTS_DIR/tcl/check_jtag.tcl")"
