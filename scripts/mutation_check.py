#!/usr/bin/env python3
"""Mutation check: inject one known bug at a time into the RTL and run the testbench.

Every mutant must be caught (the testbench must fail). A mutant that still prints
TEST PASSED has escaped, and the script exits with an error.

Usage:
    python scripts/mutation_check.py [ip_name]

Writes ip/<ip_name>/results/mutation_summary.txt.
Needs Python 3 and GHDL in the PATH. Works on Windows, Linux and macOS.
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name: (RTL file, text to replace, replacement). The text must occur in the RTL file.
MUTANTS = {
    "async_fifo": {
        "M1 binary pointer crosses (no Gray)": (
            "async_fifo.vhd",
            "wr_gray_q <= bin_to_gray(wr_next);",
            "wr_gray_q <= std_logic_vector(wr_next);",
        ),
        "M2 read synchronizer bypassed": (
            "async_fifo.vhd",
            "gray_to_bin(wr_gray_sync_q(SYNC_STAGES - 1)) - rd_bin_q",
            "gray_to_bin(wr_gray_sync_q(0)) - rd_bin_q",
        ),
        "M3 full one word early": (
            "async_fifo.vhd",
            "full  <= wr_level(ADDR_W);",
            "full  <= '1' when wr_level >= DEPTH - 1 else '0';",
        ),
        "M4 empty from the unsynchronized pointer": (
            "async_fifo.vhd",
            "gray_to_bin(wr_gray_sync_q(SYNC_STAGES - 1)) - rd_bin_q",
            "gray_to_bin(wr_gray_q) - rd_bin_q",
        ),
        "M5 extra pointer bit ignored in full": (
            "async_fifo.vhd",
            "full  <= wr_level(ADDR_W);",
            "full  <= '1' when wr_level(ADDR_W - 1 downto 0) = 0 else '0';",
        ),
        "M6 read pointer not reset": (
            "async_fifo.vhd",
            "        rd_bin_q       <= (others => '0');\n",
            "",
        ),
        "M7 levels swapped": (
            "async_fifo.vhd",
            "wr_level_o <= std_logic_vector(wr_level);",
            "wr_level_o <= std_logic_vector(rd_level);",
        ),
        "M8 data written one slot late": (
            "async_fifo.vhd",
            "mem(to_integer(wr_bin_q(ADDR_W - 1 downto 0))) <= wr_data_i;",
            "mem(to_integer(wr_bin_q(ADDR_W - 1 downto 0) + 1)) <= wr_data_i;",
        ),
        "M9 write synchronizer bypassed": (
            "async_fifo.vhd",
            "wr_level <= wr_bin_q - gray_to_bin(rd_gray_sync_q(SYNC_STAGES - 1));",
            "wr_level <= wr_bin_q - gray_to_bin(rd_gray_q);",
        ),
        "M10 write pointer not reset": (
            "async_fifo.vhd",
            "        wr_bin_q       <= (others => '0');\n",
            "",
        ),
    },
}

# Testbench runs used to hunt a mutant: first one that fails catches it.
GENERICS = {
    "async_fifo": [
        ["WIDTH=8", "DEPTH=16", "SYNC_STAGES=2", "WR_PS=10000", "RD_PS=10000", "RD_PHASE_PS=3000"],
        ["WIDTH=8", "DEPTH=16", "SYNC_STAGES=2", "WR_PS=10000", "RD_PS=7000", "RD_PHASE_PS=1234"],
        ["WIDTH=8", "DEPTH=16", "SYNC_STAGES=2", "WR_PS=7000", "RD_PS=10000", "RD_PHASE_PS=555"],
    ],
}


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)


def last_message(out: str) -> str:
    for line in out.splitlines():
        if "failure" in line or "error" in line or "coverage:" in line:
            return line.split("):", 1)[-1].strip()[:80]
    return "testbench failed"


def main() -> int:
    ip = sys.argv[1] if len(sys.argv) > 1 else "async_fifo"
    if ip not in MUTANTS:
        print(f"no mutants defined for '{ip}' in scripts/mutation_check.py")
        return 2
    if shutil.which("ghdl") is None:
        print("ghdl not found in PATH. Install GHDL and reopen the terminal.")
        return 2

    ip_dir = ROOT / "ip" / ip
    rtl = sorted(ip_dir.glob("rtl/*.vhd"), key=lambda p: (not p.stem.endswith("_pkg"), p.name))
    tb = sorted(ip_dir.glob("tb/*.vhd"))
    tb_unit = f"{ip}_tb"

    lines = [f"{ip}: mutation check", "", f"Command: python scripts/mutation_check.py {ip}", ""]
    escaped = 0
    for name, (fname, old, new) in MUTANTS[ip].items():
        original = (ip_dir / "rtl" / fname).read_text(encoding="utf-8")
        if old not in original:
            print(f"{name}: pattern not found in {fname}, update the mutant")
            return 2
        work = ROOT / "build" / "mutation" / ip
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        mutated = work / fname
        mutated.write_text(original.replace(old, new, 1), encoding="utf-8", newline="\n")

        files = [str(mutated if p.name == fname else p) for p in rtl] + [str(p) for p in tb]
        res = run(["ghdl", "-a", "--std=08", f"--workdir={work}"] + files)
        if res.returncode != 0:
            print(f"{name}: ANALYSIS ERROR, fix the mutant\n{res.stderr[:400]}")
            return 2

        verdict = "ESCAPED"
        for gens in GENERICS[ip]:
            cmd = ["ghdl", "--elab-run", "--std=08", f"--workdir={work}"]
            cmd += [f"-g{g}" for g in gens] + [tb_unit]
            res = run(cmd)
            out = res.stdout + res.stderr
            if res.returncode != 0 or "TEST PASSED" not in out:
                verdict = "CAUGHT: " + last_message(out)
                break
        if verdict == "ESCAPED":
            escaped += 1
        print(f"{name}: {verdict}")
        lines.append(f"{name}: {verdict}")

    total = len(MUTANTS[ip])
    summary = f"{total - escaped} of {total} mutants caught"
    lines += ["", summary]
    print(summary)
    results = ip_dir / "results"
    results.mkdir(exist_ok=True)
    (results / "mutation_summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return 1 if escaped else 0


if __name__ == "__main__":
    sys.exit(main())