#!/usr/bin/env python3
"""Compile an IP with GHDL and run its testbench in several configurations.

Works on Windows, Linux and macOS (only needs Python 3 and GHDL in the PATH).

Usage:
    python scripts/run_sim.py [ip_name]

Writes ip/<ip_name>/results/sim_summary.txt with the command and the result
of each configuration.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (WIDTH, DEPTH) configurations simulated for each IP (SPEC section 9)
CONFIGS = {
    "sync_fifo": [(1, 2), (8, 16), (32, 1024)],
}


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def main() -> int:
    ip = sys.argv[1] if len(sys.argv) > 1 else "sync_fifo"
    ip_dir = ROOT / "ip" / ip
    if not ip_dir.is_dir():
        print(f"unknown IP '{ip}'")
        return 2
    if shutil.which("ghdl") is None:
        print("ghdl not found in PATH. Install GHDL and reopen the terminal.")
        return 2

    rtl = sorted(ip_dir.glob("rtl/*.vhd"), key=lambda p: (not p.stem.endswith("_pkg"), p.name))
    tb = sorted(ip_dir.glob("tb/*.vhd"))
    work = ROOT / "build" / "ghdl" / ip
    work.mkdir(parents=True, exist_ok=True)

    analyze = ["ghdl", "-a", "--std=08", f"--workdir={work}"] + [str(p) for p in rtl + tb]
    res = run(analyze, ROOT)
    if res.returncode != 0:
        print("analysis FAILED")
        print(res.stdout + res.stderr)
        return 1

    tb_unit = f"{ip}_tb"
    lines = [f"{ip}: simulation summary", "", "Command: python scripts/run_sim.py " + ip, ""]
    ok_all = True
    for width, depth in CONFIGS[ip]:
        cmd = [
            "ghdl", "--elab-run", "--std=08", f"--workdir={work}",
            f"-gWIDTH={width}", f"-gDEPTH={depth}", tb_unit,
        ]
        res = run(cmd, ROOT)
        out = res.stdout + res.stderr
        passed = res.returncode == 0 and "TEST PASSED" in out
        ok_all &= passed
        status = "PASS" if passed else "FAIL"
        print(f"WIDTH={width:3d} DEPTH={depth:5d}: {status}")
        lines.append(f"WIDTH={width} DEPTH={depth}: {status}")
        for m in re.finditer(r"@\S+:\(report note\): (coverage|transfers):.*", out):
            lines.append("    " + m.group(0).split("(report note): ", 1)[1])
        if not passed:
            print(out)
        lines.append("")

    results = ip_dir / "results"
    results.mkdir(exist_ok=True)
    (results / "sim_summary.txt").write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("ALL PASSED" if ok_all else "SOME FAILED")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
