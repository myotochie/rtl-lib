# sync_fifo: specification

**Status:** frozen for 0.1.0
**Version:** 0.1.0 (target)
**Languages:** VHDL-2008 / SystemVerilog (same behavior in both)

## 1. Summary

A single-clock FIFO with parameterizable data width and depth. Both sides use the valid/ready
handshake defined in `docs/CONVENTIONS.md`, so it connects to any stream-style producer or
consumer without glue logic. Reads are first-word fall-through: the oldest word is on
`rd_data_o` as soon as `rd_valid_o` is high.

Backpressure is the only flow control. The FIFO never overflows, never underflows, and never
drops or reorders a word.

## 2. Parameters

| Name | Type | Default | Legal range | Meaning |
|---|---|---|---|---|
| `WIDTH` | positive integer | 8 | 1 to 1024 | Data width in bits |
| `DEPTH` | positive integer | 16 | power of two, 2 to 4096 | Number of words stored |

Derived values (not parameters): `ADDR_W = log2(DEPTH)`. `level_o` is `ADDR_W + 1` bits wide.

Illegal values are rejected by an assertion at elaboration time (CONVENTIONS section 6).

## 3. Ports

| Name | Direction | Width | Clock domain | Description |
|---|---|---|---|---|
| `clk_i` | in | 1 | n/a | Clock, rising edge |
| `rst_n_i` | in | 1 | `clk_i` | Synchronous active-low reset |
| `wr_valid_i` | in | 1 | `clk_i` | Producer has a word to write |
| `wr_ready_o` | out | 1 | `clk_i` | FIFO can accept a word (not full) |
| `wr_data_i` | in | `WIDTH` | `clk_i` | Word to write, qualified by `wr_valid_i` |
| `rd_valid_o` | out | 1 | `clk_i` | FIFO holds a word (not empty) |
| `rd_ready_i` | in | 1 | `clk_i` | Consumer accepts the word |
| `rd_data_o` | out | `WIDTH` | `clk_i` | Oldest word, meaningful when `rd_valid_o` is high |
| `level_o` | out | `ADDR_W + 1` | `clk_i` | Number of words stored, 0 to `DEPTH` |

## 4. Interfaces and protocol

Both sides follow CONVENTIONS section 5.

- **Write transfer:** a rising clock edge where `wr_valid_i` and `wr_ready_o` are both high.
- **Read transfer:** a rising clock edge where `rd_valid_o` and `rd_ready_i` are both high.
- `wr_ready_o` and `rd_valid_o` depend only on registered state. Neither depends combinationally
  on `wr_valid_i`, `rd_ready_i` or `wr_data_i`.
- Once `rd_valid_o` is high, it stays high and `rd_data_o` stays stable until the read transfer
  happens.
- A write transfer and a read transfer may happen on the same edge.
- Latency: a word written at edge N is visible on `rd_data_o` right after edge N and can be read
  at edge N+1.

## 5. Behavior

State: a storage array of `DEPTH` words of `WIDTH` bits, a write pointer `wr_ptr` and a read
pointer `rd_ptr`. Both pointers are `ADDR_W + 1` bits wide (one extra most significant bit).

| Item | Definition |
|---|---|
| empty | `wr_ptr == rd_ptr` |
| full | pointers equal in the low `ADDR_W` bits and different in the most significant bit |
| `wr_ready_o` | not full |
| `rd_valid_o` | not empty |
| `rd_data_o` | `mem[rd_ptr low bits]`, read without a clock edge |
| `level_o` | `wr_ptr - rd_ptr`, modulo 2^(`ADDR_W + 1`) |

On a write transfer: `mem[wr_ptr low bits] <= wr_data_i` and `wr_ptr <= wr_ptr + 1`.
On a read transfer: `rd_ptr <= rd_ptr + 1`.

Reset: on any edge with `rst_n_i` low, both pointers go to 0 and handshakes on that edge are
ignored. The storage array is not reset.

## 6. Corner cases

| Case | Expected behavior |
|---|---|
| Write offered while full | Not accepted (`wr_ready_o` low). The producer holds `wr_valid_i` and the data. Nothing is lost. |
| `rd_ready_i` high while empty | Ignored (`rd_valid_o` low). Nothing happens. |
| Write and read on the same edge, 0 < level < `DEPTH` | Both happen. Level is unchanged. |
| Write offered while empty | Accepted. Level becomes 1 after the edge. The word can be read at the next edge (no same-edge bypass). |
| Read on the same edge as a write offer while full | Read happens, write is refused (no same-edge bypass). Level becomes `DEPTH - 1`. |
| Back-to-back traffic after a full FIFO | The write side is blocked for exactly one cycle, then runs at 1 word per cycle again. |
| Pointer wrap-around | Pointers wrap modulo 2^(`ADDR_W + 1`). Full and empty stay correct across the wrap. |
| Reset while words are stored | Contents are discarded. After the edge, level is 0 and `rd_valid_o` is low. |
| Smallest configuration | `WIDTH = 1`, `DEPTH = 2` behaves like every other configuration. |
| `DEPTH` not a power of two, or out of range | Elaboration fails with an assertion message. |

## 7. Architecture

**Chosen:** two pointers with one extra bit. Full and empty come from comparing the pointers, and
the level is their difference. No counter is needed, and all `DEPTH` words are usable.

**Alternatives discarded:**

- *Up/down counter for the level:* more logic on the update path, and the level is already
  available from the pointers.
- *Pointers without the extra bit, one slot kept empty:* wastes one word. The spec promises
  exactly `DEPTH` words.
- *Registered read output (block-RAM friendly):* adds one cycle of read latency and an output
  stage. Not needed for 0.1.0. Planned as a later parameter.
- *Same-edge bypass when empty or full:* creates combinational paths between the write side and
  the read side, and breaks the rule that `wr_ready_o` and `rd_valid_o` depend only on state.

## 8. Target metrics

| Metric | Target | Measured | Script |
|---|---|---|---|
| Throughput | 1 word per cycle on each side while level stays between 1 and `DEPTH - 1` | - | - |
| Write-to-read latency | 1 cycle | - | - |
| Recovery after full | write side blocked for 1 cycle, then full rate | - | - |
| Resources | storage array, two (`ADDR_W + 1`)-bit pointers, two comparators, no counter | - | - |
| fmax | set after the first synthesis run, then frozen as a regression threshold | - | - |

## 9. Verification plan

| Feature | Check (assertion, scoreboard, proof) | Coverage item |
|---|---|---|
| Data integrity and order | Scoreboard against a reference queue | Every level from 0 to `DEPTH` reached |
| No overflow | Assertion and formal proof: level never above `DEPTH` | Write offered while full |
| No underflow | Assertion and formal proof: no read transfer while empty | `rd_ready_i` high while empty |
| `level_o` correctness | Scoreboard compares `level_o` with the reference queue size | Level at each cycle |
| Output stability | Assertion: if `rd_valid_o` and not `rd_ready_i`, then next cycle `rd_valid_o` stays high and `rd_data_o` is unchanged | Stall of several cycles |
| Same-edge read and write | Scoreboard | At level 0, in the middle, and at `DEPTH` |
| Pointer wrap-around | Scoreboard | Both pointers wrap at least once |
| Reset | Assertion: level 0 and `rd_valid_o` low after reset | Reset with words stored |
| Parameter legality | Elaboration assertion | Illegal `DEPTH` rejected |

Configurations simulated: (`WIDTH`, `DEPTH`) = (1, 2), (8, 16), (32, 1024).
Coverage numbers and the regression command go in `results/`.

## 10. Limits

- Single clock domain. Crossing clock domains needs the asynchronous FIFO, a separate IP.
- The storage array is read without a clock edge. On AMD/Xilinx devices this infers distributed
  RAM (LUTRAM), not block RAM. This is why `DEPTH` is capped at 4096.
- No `almost_full` or `almost_empty` flags. `level_o` covers that need.
- No same-edge bypass: a word needs one cycle to cross the FIFO.
- `rd_data_o` is undefined while `rd_valid_o` is low.
- The storage array is not reset.

## 11. References

- `docs/CONVENTIONS.md`, sections 3 to 6 (naming, reset, handshake, parameters).