#!/usr/bin/env python3
"""Compile an IP with GHDL and run its testbench in several configurations.

Works on Windows, Linux and macOS (only needs Python 3 and GHDL in the PATH).

Usage:
    python scripts/run_sim.py [ip_name]

Writes ip/<ip_name>/results/sim_summary.txt with the command and the result
of each configuration.

Two kinds of runs per IP:
  - CONFIGS: the testbench must print TEST PASSED.
  - ILLEGAL: illegal parameter values. The run must fail with the expected
    message (elaboration assertion, CONVENTIONS section 6).
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def g(**kw):
    return kw


# Clock configurations (write period ps, read period ps, read phase ps) for async_fifo.
# The last two are 100:1 and 1:100: slow, so they are not used in every configuration.
RATIOS_BASE = [
    (10000, 10000, 0),       # equal clocks, same phase
    (10000, 10000, 5000),    # equal clocks, opposite phase
    (10000, 5000, 1234),     # read clock 2x faster
    (5000, 10000, 777),      # write clock 2x faster
    (30000, 70000, 1111),    # 3:7
    (70000, 30000, 2222),    # 7:3
]
RATIOS_EXTREME = [
    (1000, 100000, 500),     # write clock 100x faster
    (100000, 1000, 333),     # read clock 100x faster
]
RATIOS_EQUAL = RATIOS_BASE[:2]


def async_cfgs(width, depth, stages, ratios):
    return [
        g(WIDTH=width, DEPTH=depth, SYNC_STAGES=stages, WR_PS=w, RD_PS=r, RD_PHASE_PS=p)
        for (w, r, p) in ratios
    ]


# Generics of each simulated configuration (SPEC section 9 of each IP).
CONFIGS = {
    "sync_fifo": [g(WIDTH=1, DEPTH=2), g(WIDTH=8, DEPTH=16), g(WIDTH=32, DEPTH=1024)],
    "async_fifo": (
        async_cfgs(1, 4, 2, RATIOS_BASE + RATIOS_EXTREME)
        + async_cfgs(8, 16, 2, RATIOS_BASE)
        + async_cfgs(32, 256, 3, RATIOS_BASE + RATIOS_EXTREME)
        + async_cfgs(16, 32, 4, RATIOS_EQUAL)
    ),
}

# Illegal parameter values: (generics, text expected in the failure message).
ILLEGAL = {
    "sync_fifo": [
        (g(DEPTH=6), "sync_fifo: DEPTH must be a power of two"),
        (g(DEPTH=8192), "sync_fifo: DEPTH must be a power of two"),
        (g(WIDTH=2000), "sync_fifo: WIDTH must be 1 to 1024"),
    ],
    "async_fifo": [
        (g(DEPTH=6), "async_fifo: DEPTH must be a power of two"),
        (g(DEPTH=2), "async_fifo: DEPTH must be a power of two"),
        (g(SYNC_STAGES=1), "async_fifo: SYNC_STAGES must be 2 to 4"),
        (g(SYNC_STAGES=5), "async_fifo: SYNC_STAGES must be 2 to 4"),
        (g(WIDTH=2000), "async_fifo: WIDTH must be 1 to 1024"),
    ],
}


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def label(gen):
    return " ".join(f"{k}={v}" for k, v in gen.items())


def sim_cmd(work, tb_unit, gen):
    return (
        ["ghdl", "--elab-run", "--std=08", f"--workdir={work}"]
        + [f"-g{k}={v}" for k, v in gen.items()]
        + [tb_unit]
    )


def main() -> int:
    ip = sys.argv[1] if len(sys.argv) > 1 else "sync_fifo"
    ip_dir = ROOT / "ip" / ip
    if not ip_dir.is_dir():
        print(f"unknown IP '{ip}'")
        return 2
    if ip not in CONFIGS:
        print(f"no simulation configuration for '{ip}' in scripts/run_sim.py")
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

    for index, gen in enumerate(CONFIGS[ip]):
        gen = dict(gen, SEED=index + 1) if ip == "async_fifo" else gen
        res = run(sim_cmd(work, tb_unit, gen), ROOT)
        out = res.stdout + res.stderr
        passed = res.returncode == 0 and "TEST PASSED" in out
        ok_all &= passed
        status = "PASS" if passed else "FAIL"
        print(f"{label(gen)}: {status}")
        lines.append(f"{label(gen)}: {status}")
        for m in re.finditer(r"@\S+:\(report note\): (coverage|transfers):.*", out):
            lines.append("    " + m.group(0).split("(report note): ", 1)[1])
        if not passed:
            print(out)
        lines.append("")

    lines.append("Illegal parameters (the run must fail with the expected message):")
    for gen, expected in ILLEGAL[ip]:
        res = run(sim_cmd(work, tb_unit, gen), ROOT)
        out = res.stdout + res.stderr
        rejected = res.returncode != 0 and expected in out
        ok_all &= rejected
        status = "REJECTED" if rejected else "NOT REJECTED"
        print(f"illegal {label(gen)}: {status}")
        lines.append(f"  {label(gen)}: {status}")
        if not rejected:
            print(out)
    lines.append("")

    results = ip_dir / "results"
    results.mkdir(exist_ok=True)
    (results / "sim_summary.txt").write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("ALL PASSED" if ok_all else "SOME FAILED")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())