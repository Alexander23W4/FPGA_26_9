#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-/e/PythonVersionEnv/Python3.14.0/python.exe}"
INITIAL_IMAGE="${1:-/e/camus/images/testing/patient0027/patient0027_4CH_ED.png}"
FPGA_HOST="${FPGA_IP:-192.168.1.10}"
SERIAL_PORT="${SERIAL_PORT:-COM7}"

if [[ ! -x "$PYTHON" ]]; then
  echo "Python interpreter not found or not executable: $PYTHON" >&2
  echo "Set PYTHON=/path/to/python.exe and retry." >&2
  exit 1
fi

if [[ ! -f "$INITIAL_IMAGE" ]]; then
  echo "Initial image not found: $INITIAL_IMAGE" >&2
  echo "Pass a valid image path as the first argument." >&2
  exit 1
fi

cd "$ROOT"

"$PYTHON" - <<'PY'
import socket
import sys

try:
    with socket.create_connection(("127.0.0.1", 8765), timeout=0.25):
        print("GUI port 8765 is already in use. Stop the existing GUI and retry.", file=sys.stderr)
        raise SystemExit(1)
except OSError:
    raise SystemExit(0)
PY

exec "$PYTHON" ./network/host/monitor_network.py \
  --board-ip "$FPGA_HOST" --control-port 5000 --image-port 5001 \
  --transfer-ip "$FPGA_HOST" --transfer-port 5002 --serial-port "$SERIAL_PORT" \
  --result-dir E:/fpga_done_img --image "$INITIAL_IMAGE"
