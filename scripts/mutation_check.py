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
    "crc": {
        "C1 refin: bit order not swapped": (
            "crc_pkg.vhd",
            "        b := d(i);\n",
            "        b := d(d'high - i);\n",
        ),
        "C2 polynomial applied when feedback is 0": (
            "crc_pkg.vhd",
            "if fb = '1' then",
            "if fb = '0' then",
        ),
        "C3 data bit left out of the feedback": (
            "crc_pkg.vhd",
            "fb := c(c'high) xor b;",
            "fb := c(c'high);",
        ),
        "C4 output not reflected": (
            "crc_pkg.vhd",
            "      c := reverse(c);",
            "      null;",
        ),
        "C5 xorout ignored": (
            "crc_pkg.vhd",
            "return c xor x;",
            "return c;",
        ),
        "C6 last bit of the word skipped": (
            "crc_pkg.vhd",
            "for i in 0 to d'length - 1 loop",
            "for i in 0 to d'length - 2 loop",
        ),
        "C7 reverse is the identity": (
            "crc_pkg.vhd",
            "r(i) := n(n'high - i);",
            "r(i) := n(i);",
        ),
        "C8 hex digit A to F off by one": (
            "crc_pkg.vhd",
            "character'pos(c) - character'pos('A') + 10;",
            "character'pos(c) - character'pos('A') + 11;",
        ),
        "C9 hex digit a to f off by one": (
            "crc_pkg.vhd",
            "character'pos(c) - character'pos('a') + 10;",
            "character'pos(c) - character'pos('a') + 9;",
        ),
        "C10 start_i ignored": (
            "crc.vhd",
            "if start_i = '1' then",
            "if false then",
        ),
        "C11 start_i loads zero instead of INIT": (
            "crc.vhd",
            "base := INIT_V;",
            "base := (others => '0');",
        ),
        "C12 reset value is zero": (
            "crc.vhd",
            "          state <= INIT_V;\n        elsif",
            "          state <= (others => '0');\n        elsif",
        ),
        "C13 clear_i ignored": (
            "crc.vhd",
            "if rst_n_i = '0' or clear_i = '1' then",
            "if rst_n_i = '0' then",
        ),
        "C14 reset ignored": (
            "crc.vhd",
            "if rst_n_i = '0' or clear_i = '1' then",
            "if clear_i = '1' then",
        ),
        "C15 valid_i ignored": (
            "crc.vhd",
            "elsif valid_i = '1' then",
            "else",
        ),
        "C16 start_i alone updates the register": (
            "crc.vhd",
            "elsif valid_i = '1' then",
            "elsif valid_i = '1' or start_i = '1' then",
        ),
        "C17 valid_i wins over clear_i": (
            "crc.vhd",
            "if rst_n_i = '0' or clear_i = '1' then",
            "if rst_n_i = '0' or (clear_i = '1' and valid_i = '0') then",
        ),
        "C18 output reflection inverted": (
            "crc.vhd",
            "crc_final(state, XOROUT_V, REFOUT)",
            "crc_final(state, XOROUT_V, not REFOUT)",
        ),
    },
    "uart": {
        "T1 tx bit one cycle short": (
            "uart_tx.vhd",
            "if cnt_q = N - 1 then\n            cnt_q <= 0;",
            "if cnt_q = N - 2 then\n            cnt_q <= 0;",
        ),
        "T2 tx parity bit inverted": (
            "uart_tx.vhd",
            "word(DATA_BITS) := parity_bit(tx_data_i, PARITY);",
            "word(DATA_BITS) := not parity_bit(tx_data_i, PARITY);",
        ),
        "T3 tx not ready in the last cycle (gap between frames)": (
            "uart_tx.vhd",
            "ready      <= run_q and (not busy_q or last_clk);",
            "ready      <= run_q and not busy_q;",
        ),
        "T4 tx stop bit sent low": (
            "uart_tx.vhd",
            "word := (others => '1');",
            "word := (others => '0');",
        ),
        "T5 tx ready during reset": (
            "uart_tx.vhd",
            "ready      <= run_q and (not busy_q or last_clk);",
            "ready      <= (not busy_q or last_clk);",
        ),
        "T6 parity polarity swapped (package)": (
            "uart_pkg.vhd",
            "if mode = 2 then\n      p := not p;",
            "if mode = 1 then\n      p := not p;",
        ),
        "R1 single sample instead of majority vote": (
            "uart_rx.vhd",
            "if (a_q and b_q) = '1' or (a_q and line_s) = '1' or (b_q and line_s) = '1' then",
            "if b_q = '1' then",
        ),
        "R2 false start accepted": (
            "uart_rx.vhd",
            "if v = '1' then\n                busy_q <= '0';",
            "if v = '1' then\n                busy_q <= '1';",
        ),
        "R3 sampling window a quarter bit early": (
            "uart_rx.vhd",
            "cnt_q  <= 1;",
            "cnt_q  <= 1 + N / 4;",
        ),
        "R4 parity error polarity inverted": (
            "uart_rx.vhd",
            "perr := acc_q;",
            "perr := not acc_q;",
        ),
        "R5 last stop bit not checked": (
            "uart_rx.vhd",
            "ferr   := ferr_q or not v;",
            "ferr   := ferr_q;",
        ),
        "R6 first of two stop bits not checked": (
            "uart_rx.vhd",
            "ferr_q <= '1';",
            "ferr_q <= '0';",
        ),
        "R7 overrun overwrites the old word": (
            "uart_rx.vhd",
            "if out_valid_q = '0' or rx_ready_i = '1' then",
            "if true then",
        ),
        "R8 overrun pulse missing": (
            "uart_rx.vhd",
            "overrun_q <= '1';",
            "overrun_q <= '0';",
        ),
        "R9 data received MSB first": (
            "uart_rx.vhd",
            "shift_q <= v & shift_q(DATA_BITS - 1 downto 1);",
            "shift_q <= shift_q(DATA_BITS - 2 downto 0) & v;",
        ),
        "R10 synchronizer resets to 1": (
            "uart_rx.vhd",
            'sync_q      <= "00";',
            'sync_q      <= "11";',
        ),
        "R11 parity bit not accumulated": (
            "uart_rx.vhd",
            "elsif idx_q <= DATA_BITS + P_LEN then\n              acc_q   <= acc_q xor v;",
            "elsif idx_q <= DATA_BITS + P_LEN then\n              acc_q   <= acc_q;",
        ),
        "R12 valid never cleared": (
            "uart_rx.vhd",
            "if out_valid_q = '1' and rx_ready_i = '1' then\n          out_valid_q <= '0';",
            "if out_valid_q = '1' and rx_ready_i = '1' then\n          out_valid_q <= '1';",
        ),
        "R13 frame starts on a low level, not an edge": (
            "uart_rx.vhd",
            "if prev_q = '1' and line_s = '0' then",
            "if line_s = '0' then",
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
    "crc": [
        ["CRC_WIDTH=32", "DATA_WIDTH=8", "POLY=04c11db7", "INIT=ffffffff", "XOROUT=ffffffff",
         "REFIN=true", "REFOUT=true", "CHECK=cbf43926", "MESSAGES=40"],
        ["CRC_WIDTH=16", "DATA_WIDTH=16", "POLY=1021", "INIT=FFFF", "XOROUT=0000",
         "REFIN=false", "REFOUT=false", "CHECK=29B1", "MESSAGES=40"],
        ["CRC_WIDTH=8", "DATA_WIDTH=5", "POLY=31", "INIT=00", "XOROUT=00",
         "REFIN=true", "REFOUT=true", "CHECK=A1", "MESSAGES=40"],
        ["CRC_WIDTH=32", "DATA_WIDTH=32", "POLY=04C11DB7", "INIT=FFFFFFFF", "XOROUT=FFFFFFFF",
         "REFIN=false", "REFOUT=true", "MESSAGES=40"],
        ["CRC_WIDTH=5", "DATA_WIDTH=1", "POLY=05", "INIT=1F", "XOROUT=1F",
         "REFIN=true", "REFOUT=false", "CHECK=19", "MESSAGES=40"],
        ["CRC_WIDTH=64", "DATA_WIDTH=64", "POLY=42F0E1EBA9EA3693", "INIT=FFFFFFFFFFFFFFFF",
         "XOROUT=FFFFFFFFFFFFFFFF", "REFIN=true", "REFOUT=true", "MESSAGES=40"],
    ],
    "uart": [
        ["BAUD=6250000", "DATA_BITS=8", "PARITY=1", "STOP_BITS=2", "SEED=2"],
        ["BAUD=3030303", "DATA_BITS=8", "PARITY=2", "STOP_BITS=2", "SEED=5"],
        ["BAUD=1000000", "DATA_BITS=8", "PARITY=0", "STOP_BITS=1", "SEED=7"],
        ["BAUD=5000000", "DATA_BITS=7", "PARITY=1", "STOP_BITS=1", "SEED=4"],
    ],
}


def compile_order(ip):
    """Packages first, then sub-entities, then the top entity (named like the IP)."""
    return lambda p: (0 if p.stem.endswith("_pkg") else 2 if p.stem == ip else 1, p.name)


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
    rtl = sorted(ip_dir.glob("rtl/*.vhd"), key=compile_order(ip))
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