# crc: specification

**Status:** draft
**Version:** 0.5.0
**Language:** VHDL-2008

## 1. Summary

`crc` computes any CRC of the Rocksoft parameter model (width, polynomial, initial value, input and output reflection, final xor) on `DATA_WIDTH` bits per clock cycle. One word is accepted every cycle, there is no back-pressure, and the CRC of the message so far is available on `crc_o` one cycle after each word. The same RTL gives CRC-32 for Ethernet, CRC-16 for Modbus or XMODEM, CRC-8, CRC-64 and others, by changing generics only. The behavior is checked against the check values of 16 catalogue algorithms.

## 2. Parameters

| Name | Type | Default | Legal range | Meaning |
|---|---|---|---|---|
| `CRC_WIDTH` | integer | 32 | 3 to 64 | Width of the CRC |
| `DATA_WIDTH` | integer | 8 | 1 to 64 | Bits processed per accepted word |
| `POLY` | string | `"04C11DB7"` | hexadecimal, fits in `CRC_WIDTH` bits, odd | Polynomial without the x^`CRC_WIDTH` term |
| `INIT` | string | `"FFFFFFFF"` | hexadecimal, fits in `CRC_WIDTH` bits | Register value before the first word |
| `XOROUT` | string | `"FFFFFFFF"` | hexadecimal, fits in `CRC_WIDTH` bits | Value xored with the output |
| `REFIN` | boolean | true | | Bit order inside a word, see section 5 |
| `REFOUT` | boolean | true | | Reflect the register before `XOROUT` |

Hexadecimal strings have no prefix, upper or lower case, and may have more digits than needed if the extra high digits are zero. An illegal value stops the elaboration with a message starting with `crc: ` (section 6).

## 3. Ports

| Name | Direction | Width | Clock domain | Description |
|---|---|---|---|---|
| `clk_i` | in | 1 | | Clock |
| `rst_n_i` | in | 1 | `clk_i` | Synchronous active-low reset |
| `clear_i` | in | 1 | `clk_i` | Restart: the CRC becomes the one of the empty message |
| `valid_i` | in | 1 | `clk_i` | `data_i` is a word of the message |
| `start_i` | in | 1 | `clk_i` | With `valid_i`: this word is the first of a message |
| `data_i` | in | `DATA_WIDTH` | `clk_i` | Message word |
| `crc_o` | out | `CRC_WIDTH` | `clk_i` | CRC of the message accepted so far |

## 4. Interfaces and protocol

The input is a strobe interface, not valid/ready: every cycle with `valid_i = 1` is a transfer, the IP cannot refuse a word. Inputs `data_i` and `start_i` are ignored when `valid_i = 0`.

Priority in one clock edge, highest first: `rst_n_i = 0`, `clear_i = 1`, `valid_i = 1`. A word presented in the same cycle as `clear_i` is dropped.

`crc_o` is combinational from the register: the CRC of a word accepted at edge k is on `crc_o` after edge k, and is held while `valid_i = 0`. The output is valid after reset (CRC of the empty message) and may be read at any time.

## 5. Behavior

Model: register `state` of `CRC_WIDTH` bits, always in the non-reflected form.

- Reset or `clear_i`: `state := INIT`.
- Word accepted with `start_i = 0`: `state := step(state, data_i)`.
- Word accepted with `start_i = 1`: `state := step(INIT, data_i)`. The previous message is discarded without needing `clear_i`.
- `step` processes the bits of the word one after the other: `fb := state(high) xor bit; state := state shifted left by one; if fb then state := state xor POLY`.
- Output: `crc_o := (REFOUT ? reverse(state) : state) xor XOROUT`.

Bit order inside a word:

- `REFIN = false`: `data_i(DATA_WIDTH-1)` first, down to `data_i(0)`. A message of bytes sent MSB first, big-endian, is a word per byte or the bytes concatenated with the first byte in the high bits.
- `REFIN = true`: `data_i(0)` first, up to `data_i(DATA_WIDTH-1)`. Bytes are in little-endian order: the first byte of the message is in `data_i(7 downto 0)`.

With these two conventions a message of `DATA_WIDTH`-bit words gives the same CRC as the same bytes sent through a 8-bit instance (checked by `ip/crc/model/crc_model.py`, 960 random messages). The CRC of the empty message is `crc_o` after reset or `clear_i`.

## 6. Corner cases

| Case | Expected behavior |
|---|---|
| `CRC_WIDTH` outside 3 to 64 | `crc: CRC_WIDTH must be 3 to 64`, elaboration failure |
| `DATA_WIDTH` outside 1 to 64 | `crc: DATA_WIDTH must be 1 to 64`, elaboration failure |
| A string is empty or not hexadecimal | `crc: POLY, INIT and XOROUT must be non-empty hexadecimal strings` |
| `POLY`, `INIT` or `XOROUT` does not fit in `CRC_WIDTH` bits | `crc: <name> does not fit in CRC_WIDTH bits` |
| `POLY` even | `crc: POLY must be odd (the x^0 term must be present)` |
| `clear_i` and `valid_i` in the same cycle | The word is dropped, `state := INIT` |
| `start_i = 1` with `valid_i = 0` | Ignored |
| Reset with `valid_i = 1` | Reset wins, the word is dropped |
| Empty message | `crc_o` is the CRC of the empty message, `INIT` reflected if `REFOUT` then xored with `XOROUT` |
| Message length not a multiple of `DATA_WIDTH` | Not supported, see section 10 |

## 7. Architecture

One register and one combinational network: `DATA_WIDTH` unrolled shift steps between the register (or `INIT` when `start_i = 1`) and the next register value. Synthesis reduces the network to XOR trees, so the generics cost no logic outside the XOR depth. The output reflection and the final xor are wiring and inverters only.

Alternatives discarded:

- Register in the reflected form for `REFIN = true`. This saves nothing in hardware (reflection is wiring) and doubles the cases to verify. One non-reflected register is used for every algorithm.
- A registered output. It adds one cycle of latency and `CRC_WIDTH` flip-flops for no gain; the output is already a function of one register.
- A ready signal. A CRC step never needs to wait, so the IP always accepts. Adding ready would only force users to wire a constant.
- Partial last word with byte enables. Kept out to keep the first release small, listed in section 10.

## 8. Target metrics

Out-of-context synthesis and implementation, part `xc7z010clg400-1`, Vivado 2023.1, one clock, I/O delays 0 ns, command `vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_crc.tcl -tclargs <ALGORITHM> <DATA_WIDTH> <PERIOD_NS>`. Results are reported as `TIMING=MET` at a chosen period.

| Metric | Target | Measured | Script |
|---|---|---|---|
| Area and fmax | to be measured | see `results/synth_summary.txt` | `scripts/synth_vivado_crc.tcl` |
| Latency | 1 cycle from word to `crc_o` | 1 cycle (testbench) | `scripts/run_sim.py crc` |
| Throughput | `DATA_WIDTH` bits per cycle, no stall | `DATA_WIDTH` bits per cycle (testbench) | `scripts/run_sim.py crc` |

## 9. Verification plan

| Feature | Check (assertion, scoreboard, proof) | Coverage item |
|---|---|---|
| Algorithm correctness | Catalogue check value of "123456789" for 16 algorithms (CRC-3 to CRC-64), when `DATA_WIDTH` divides 72 | check value hit |
| Algorithm correctness, any `DATA_WIDTH` | Polynomial long division of the whole message (an algorithm different from the shift register) compared with `crc_o` at the end of each message | messages, lengths 1 and 16 words |
| Cycle behavior | Per-cycle monitor with its own register model: `crc_o` compared after every clock edge, including idle cycles with junk on `start_i` and `data_i` | idle cycles with `start_i = 1` |
| `start_i`, `clear_i`, reset priorities | Five message modes: start on first word, clear then message, clear with valid and start in the same cycle, reset then message, two messages back to back | each mode, clear with valid, reset with junk |
| Gaps | Random idle cycles inside a message | gaps |
| Value held while idle | `crc_o` compared again after random idle cycles | |
| Generics | 39 configurations: 16 algorithms at `DATA_WIDTH` 8 and one of 1, 5, 12, 16, 24, 32, 64, CRC-32 at 1, 5, 16, 32, 64, lower-case hexadecimal | |
| Illegal generics | 10 illegal values, each must stop with the expected message | |
| Testbench quality | Mutation check, 18 injected bugs, all must be caught (`scripts/mutation_check.py crc`) | |
| Formal | Documented exception, see section 10 | |

Reproduction: `python ip/crc/model/crc_model.py`, `python scripts/run_sim.py crc`, `python scripts/mutation_check.py crc`.

## 10. Limits

- Messages are a whole number of `DATA_WIDTH`-bit words. For a last word shorter than the others, use a second instance with a smaller `DATA_WIDTH` or send the tail one bit at a time with `DATA_WIDTH = 1`. Byte enables are planned.
- Check values cover 16 catalogue algorithms; other parameter sets are verified against the long division model only.
- `DATA_WIDTH` x `CRC_WIDTH` sets the XOR depth: wide words at high clock rates will need pipelining. The current RTL is not pipelined, see section 8 for measured fmax.
- No formal proof yet. A formal property (the register equals the long-division CRC of the accepted words, bounded) is planned; tracked in a GitHub issue.
- Only the oddness of `POLY` is checked: a polynomial that is odd but reducible gives a valid but weak CRC. Choosing a good polynomial is the user's job.

## 11. References

- Ross Williams, "A Painless Guide to CRC Error Detection Algorithms", 1993 (Rocksoft model).
- Greg Cook, "Catalogue of parametrised CRC algorithms" (reveng.sourceforge.io/crc-catalogue), source of the check values.