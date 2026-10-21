# RTL simulation

## Vivado xsim

From the `medical_metrics` directory:

```powershell
vivado -mode batch -source sim\run_xsim.tcl
```

Expected self-check messages:

```text
PASS: registration dx=+2 dy=-1 sad=0
PASS: volume and strain arithmetic
PASS: area and long-axis extent
PASS: medical AXI-Lite map
PASS: bilinear interpolation
```

## Icarus Verilog (if installed)

```powershell
iverilog -g2012 -o tb_registration.vvp `
  rtl/sync_ram.v rtl/frame_diff_sad.v rtl/registration_search.v rtl/registration_top.v `
  sim/tb_registration_top.v
vvp tb_registration.vvp
```

Repeat with the other testbenches and the corresponding RTL files.

## Current machine status

No Vivado, iverilog, or Verilator is available in the current workspace, so
these testbenches were written but **not executed here**.  Do not report a
PASS until the simulator has actually run.

