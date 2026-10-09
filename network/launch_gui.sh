#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-/e/PythonVersionEnv/Python3.14.0/python.exe}"
INITIAL_IMAGE="${1:-/e/camus/images/testing/patient0027/patient0027_4CH_ED.png}"
MOCK_PID=""

cleanup() {
  if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
}

probe_ports() {
  "$PYTHON" - "$@" <<'PY'
import socket
import sys

states = []
for port in map(int, sys.argv[1:]):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.25):
            states.append(True)
    except OSError:
        states.append(False)

sys.exit(0 if all(states) else 2 if any(states) else 1)
PY
}

wait_for_ports() {
  "$PYTHON" - "$@" <<'PY'
import socket
import sys
import time

ports = list(map(int, sys.argv[1:]))
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    try:
        for port in ports:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                pass
        sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit(1)
PY
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

if probe_ports 8765; then
  echo "GUI port 8765 is already in use. Stop the existing GUI and retry." >&2
  exit 1
else
  GUI_PORT_STATUS=$?
  if [[ "$GUI_PORT_STATUS" -ne 1 ]]; then
    echo "Could not check whether GUI port 8765 is available." >&2
    exit 1
  fi
fi

if probe_ports 5000 5001; then
  echo "Using existing mock PS service on ports 5000 and 5001."
else
  MOCK_PORT_STATUS=$?
  if [[ "$MOCK_PORT_STATUS" -ne 1 ]]; then
    echo "Only one mock PS port is available; free ports 5000 and 5001, then retry." >&2
    exit 1
  fi

  "$PYTHON" ./network/mock/mock_ps_server.py \
    --host 127.0.0.1 --control-port 5000 --image-port 5001 &
  MOCK_PID=$!

  if ! wait_for_ports 5000 5001; then
    if ! kill -0 "$MOCK_PID" 2>/dev/null; then
      echo "Mock PS server exited before startup completed." >&2
      exit 1
    fi
    echo "Mock PS service did not open both ports 5000 and 5001." >&2
    exit 1
  fi
fi

"$PYTHON" ./network/host/monitor_network.py \
  --board-ip 127.0.0.1 --control-port 5000 --image-port 5001 \
  --image "$INITIAL_IMAGE"
