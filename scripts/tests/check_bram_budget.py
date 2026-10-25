"""Audit functional BRAM capacity using an actual Vivado hierarchy report.

This subtracts the three named passive trace IPs that debug_budget.tcl removes
before synthesis. It does not claim to run DRC or predict placement/timing.
"""
import argparse
from pathlib import Path


def audit(path):
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = [s.strip() for s in line.split("|")[1:-1]]
        if len(fields) == 10 and fields[7].isdigit() and fields[8].isdigit():
            rows.append(fields)
    roots = [r for r in rows if r[1] == "(top)"]
    if len(roots) != 1:
        raise ValueError("Expected one top-level hierarchy utilization row")
    total36, total18 = int(roots[0][7]), int(roots[0][8])
    debug36, debug18 = 0, 0
    for name in ("u_ila_hdmi", "u_ila_saxi", "u_ila_vdma_mm2s"):
        found = [r for r in rows if r[0] == name]
        if len(found) > 1:
            raise ValueError(f"Ambiguous debug hierarchy: {name}")
        if found:
            n36, n18 = int(found[0][7]), int(found[0][8])
            debug36 += n36
            debug18 += n18
            print(f"DEBUG_BRAM {name} RAMB36={n36} RAMB18={n18}")
    function36, function18 = total36 - debug36, total18 - debug18
    if min(function36, function18) < 0 or function36 > 95 or 2 * function36 + function18 > 190:
        raise ValueError(f"Functional logic exceeds Z-7015: RAMB36={function36} RAMB18={function18}")
    print(f"BRAM_AUDIT_OK total36={total36} total18={total18} functional36={function36} "
          f"functional18={function18} expected_tiles={function36 + function18 / 2:g}/95")
    print("New synthesis/implementation is required to confirm actual DRC and timing.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    audit(parser.parse_args().report)
