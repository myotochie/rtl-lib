# async_fifo: specification

**Status:** frozen for 0.3.0
**Version:** 0.0.0
**Language:** VHDL-2008

## 1. Summary

A FIFO that moves words from a write clock domain to an unrelated read clock domain. Both sides use
the valid/ready handshake of `docs/CONVENTIONS.md`. Reads are first-word fall-through, like
`sync_fifo`.

Only the read and write pointers cross between domains, Gray-coded and passed through a chain of
`SYNC_STAGES` flip-flops. The FIFO never overflows, never underflows, and never drops or reorders a
word, for any ratio and phase between the two clocks.

## 2. Parameters

| Name | Type | Default | Legal range | Meaning |
|---|---|---|---|---|
| `WIDTH` | positive integer | 8 | 1 to 1024 | Data width in bits |
| `DEPTH` | positive integer | 16 | power of two, 4 to 1024 | Number of words stored |
| `SYNC_STAGES` | positive integer | 2 | 2 to 4 | Flip-flops in each pointer synchronizer |

Derived: `ADDR_W = log2(DEPTH)`. Pointers are `ADDR_W + 1` bits wide. Levels are `ADDR_W + 1` bits wide.
Illegal values are rejected by an assertion at elaboration time (CONVENTIONS section 6).

## 3. Ports

| Name | Direction | Width | Clock domain | Description |
|---|---|---|---|---|
| `wr_clk_i` | in | 1 | n/a | Write clock, rising edge |
| `wr_rst_n_i` | in | 1 | `wr_clk_i` | Synchronous active-low reset of the write domain |
| `wr_valid_i` | in | 1 | `wr_clk_i` | Producer has a word |
| `wr_ready_o` | out | 1 | `wr_clk_i` | FIFO can accept a word |
| `wr_data_i` | in | `WIDTH` | `wr_clk_i` | Word to write |
| `wr_level_o` | out | `ADDR_W + 1` | `wr_clk_i` | Conservative occupancy, see section 5 |
| `rd_clk_i` | in | 1 | n/a | Read clock, rising edge |
| `rd_rst_n_i` | in | 1 | `rd_clk_i` | Synchronous active-low reset of the read domain |
| `rd_valid_o` | out | 1 | `rd_clk_i` | FIFO holds a readable word |
| `rd_ready_i` | in | 1 | `rd_clk_i` | Consumer accepts the word |
| `rd_data_o` | out | `WIDTH` | `rd_clk_i` | Oldest word, meaningful when `rd_valid_o` is high |
| `rd_level_o` | out | `ADDR_W + 1` | `rd_clk_i` | Conservative occupancy, see section 5 |

## 4. Interfaces and protocol

Both sides follow CONVENTIONS section 5, each in its own clock domain.

- `wr_ready_o` and `rd_valid_o` depend only on registered state of their own domain. They never
  depend combinationally on the handshake inputs or on the other clock.
- Once `rd_valid_o` is high, it stays high and `rd_data_o` stays stable until the read transfer.
- **Clocks:** no relation is assumed between `wr_clk_i` and `rd_clk_i` (any ratio, any phase).
  Both must be running while a word is expected to cross.
- **Resets:** the two resets must both be low during a window that contains at least one rising edge of each clock. They may be released in any order. A reset of one domain alone is illegal.
- **Latency (words):** a word written at write edge N can be read at read edge number `SYNC_STAGES + 1`
  to `SYNC_STAGES + 2` counted after the first read edge following N. Which one depends on the clock
  phase. (Values from the pre-RTL model, to be confirmed by simulation.)In zero-delay simulation only SYNC_STAGES + 1 occurs. SYNC_STAGES + 2 is a possible metastability outcome and cannot be simulated.
- **Latency (places):** a place freed by a read is available again to the writer after `SYNC_STAGES + 1`
  to `SYNC_STAGES + 2` write edges, by symmetry.

## 5. Behavior

State: a storage array of `DEPTH` words, written in the write domain and read in the read domain;
binary pointers `wr_ptr` and `rd_ptr` (each owned by one domain); their Gray-coded copies `wr_gray`
and `rd_gray`, **registered** in their owning domain and sent directly (no logic between that
register and the first synchronizer flip-flop); `rd_gray` synchronized into the write domain as
`rd_gray_sync`, `wr_gray` synchronized into the read domain as `wr_gray_sync`.

| Item | Definition |
|---|---|
| full | `wr_ptr - bin(rd_gray_sync) == DEPTH` (modulo 2^(`ADDR_W + 1`)) |
| empty | `rd_ptr == bin(wr_gray_sync)` |
| `wr_ready_o` | not full |
| `rd_valid_o` | not empty |
| `rd_data_o` | `mem[rd_ptr low bits]`, read without a clock edge |
| `wr_level_o` | `wr_ptr - bin(rd_gray_sync)`. Never below the true occupancy. |
| `rd_level_o` | `bin(wr_gray_sync) - rd_ptr`. Never above the true occupancy. |

A synchronized pointer is always an old value of the real pointer, so the write side may believe the
FIFO is fuller than it is, and the read side may believe it is emptier than it is. Never the reverse.
This is why the FIFO is safe, and why `wr_level_o` is an upper bound and `rd_level_o` a lower bound.

Reset: in each domain, the pointers, the registered Gray pointer and that domain's synchronizer chain
go to 0. The storage array is not reset.

## 6. Corner cases

| Case | Expected behavior |
|---|---|
| Write offered while full | Not accepted. Nothing is lost. |
| `rd_ready_i` high while empty | Ignored. |
| Word written into an empty FIFO | Becomes readable after the latency of section 4, not before. |
| Full FIFO, one word read | Writer sees the free place after the latency of section 4. |
| Equal clock frequencies, random phase | Safe. Full rate needs `DEPTH` large enough (section 8). |
| Very slow reader, fast writer, and the reverse | Safe. Backpressure only. |
| Pointer wrap-around | Gray code and extra bit stay correct across the wrap. |
| Reset of both domains with words stored | Contents discarded. Both levels 0 after both resets are released and the synchronizers are flushed. |
| Resets released in different order | Safe. A word written before the read domain leaves reset becomes readable after it does. |
| `SYNC_STAGES` or `DEPTH` out of range | Elaboration fails with an assertion message. |

## 7. Architecture

**Chosen:** two binary pointers with an extra bit, each registered as Gray code in its own domain and
crossed through `SYNC_STAGES` flip-flops. Full and empty are computed from the synchronized pointer
converted back to binary, in the domain that uses it. The storage array is written by `wr_clk_i` and
read combinationally in the read domain.

**Alternatives discarded:**

- *Binary pointers through the synchronizer:* several bits can change at once, so a capture during
  the change can return a value that was never the pointer. Not safe.
- *Gray conversion after the pointer register, before the synchronizer:* logic delay creates glitches
  on the crossing bits. The Gray value must come straight from a flip-flop.
- *Handshake or toggle synchronizers for a data word:* one word per round trip, far lower throughput.
- *Comparison in Gray code without binary conversion:* possible, but harder to read and to verify.
  Conversion is cheap at these depths.
- *Registered read output (block RAM):* adds a read latency stage. Planned as a later parameter.

## 8. Target metrics

| Metric | Target | Measured | Script |
|---|---|---|---|
| Safety | no overflow, underflow, loss or reorder, any ratio and phase | 24 clock and phase configurations, no violation | `python scripts/run_sim.py async_fifo` |
| Gray property | each crossing bus changes by one bit at most per source edge | assertion never fired | same |
| Latency | `SYNC_STAGES + 1` to `SYNC_STAGES + 2` read edges | `SYNC_STAGES + 1` in zero-delay simulation | same |
| Full rate at equal clocks | `DEPTH >= 8` for `SYNC_STAGES = 2`, `DEPTH >= 16` for 3 or 4 (pre-RTL model) | at least 0.98 word per cycle enforced in 3 configurations (`DEPTH` 16, 256, 32) | same |
| Resources | array, 2 binary pointers, 2 Gray registers, 2 synchronizers, 2 comparators | see below | `scripts/synth_vivado_async.tcl` |
| Timing | met in both domains and on both crossings | see below | same |

Synthesis and implementation (xc7z010clg400-1, Vivado 2023.1, out-of-context):

| WIDTH x DEPTH, `SYNC_STAGES` | LUT | LUTRAM | FF | BRAM | Timing met at |
|---|---|---|---|---|---|
| 8 x 16, 2 | 38 | 6 | 38 | 0 | 222 MHz |
| 8 x 16, 3 | 37 | 6 | 48 | 0 | 212 MHz |
| 32 x 1024, 2 | 924 | 704 | 109 | 0 | 151 MHz |

Each frequency is the highest one tried at which setup timing was met in both domains and on both
crossings (worst crossing slack +2.9 ns), and hold between registers was met. It is not a maximum.
The synchronizer flip-flops carry `ASYNC_REG` in every run. Details and the reproduction command:
`results/synth_summary.txt`.

## 9. Verification plan

| Feature | Check | Coverage item |
|---|---|---|
| Data integrity and order | Scoreboard against a reference queue, written by the write monitor, read by the read monitor | Every level from 0 to `DEPTH` reached |
| No overflow, no underflow | Assertions on true occupancy computed by the testbench | Write offered while full, read offered while empty |
| Level bounds | `wr_level_o >= true`, `rd_level_o <= true` at every edge | Both bounds strictly loose at least once |
| Crossing safety | Assertion: each crossing bus changes by at most one bit between two source edges | Both buses toggle through a full wrap |
| Latency | Measure and check within the range of section 4 | SYNC_STAGES + 1 observed in simulation|
| Output stability | `rd_valid_o` and `rd_data_o` stable until transfer | Several-cycle stalls |
| Clock ratios and phases | Sweep: equal, 2:1, 1:2, 3:7, 7:3, 100:1, 1:100, random phase offsets | Each ratio run |
| Reset | Both resets overlapping, released in each order, while words are stored | Both release orders |
| Parameter legality | Elaboration assertion | Illegal values rejected |

Configurations: (`WIDTH`, `DEPTH`, `SYNC_STAGES`) = (1, 4, 2), (8, 16, 2), (32, 256, 3).

**Mutants (each must be caught):** binary pointer crossing instead of Gray; Gray computed after a
logic stage; one synchronizer stage removed; full compared with `>=` shifted by one; empty computed
from the unsynchronized pointer; extra bit removed; one reset missing; `wr_level_o` and `rd_level_o`
swapped.

**Limit of the method:** a zero-delay simulation cannot show metastability or setup violations. It
can show logic errors such as a pointer crossing in binary, through the one-bit-change assertion and
the ratio and phase sweep. Timing safety comes from the integration rules in section 10 and from the
synthesis constraints.

Mutation check: python scripts/mutation_check.py async_fifo, 10 of 10 mutants caught, result in results/mutation_summary.txt.

## 10. Integration requirements

These rules are part of the contract. Without them the IP is not safe in hardware.

- The synchronizer flip-flops must be placed together and not optimized away: attribute `ASYNC_REG`
  on AMD/Xilinx.
- The crossing buses (`wr_gray` to its synchronizer, `rd_gray` to its synchronizer) get a
  `set_max_delay -datapath_only` constraint. A false path is not enough: the skew between the bits
  must stay below one source clock period.
- No logic between the Gray register and the first synchronizer flip-flop.
- Data words are not synchronized. They are protected by the pointer protocol: the word is stable
  before its pointer crosses.

## 11. Limits

- Zero-delay simulation only; no metastability model. The latency `SYNC_STAGES + 2` cannot be simulated.
- Bit skew on the Gray buses is not checked: the synthesis script bounds the delay but applies no
  `set_bus_skew`. To do.
- The storage array is read without a clock edge: distributed RAM (LUTRAM) on AMD/Xilinx, not block RAM.
  This is also what limits the frequency at large depth (timing met at 151 MHz for 32 x 1024, against
  212 MHz or more for 8 x 16).
- The critical paths of each domain go through the Gray to binary conversion, the subtraction
  and the full or empty flag, all combinational. Registered flags would raise the frequency. Not done.
- `wr_level_o` and `rd_level_o` are conservative, not exact.
- Resets must overlap (section 4).
- Synthesis results come from the out-of-context mode with 0 ns I/O delays; its port hold slack
  and `HD.CLK_SRC` warnings are not design issues. The frequencies are the highest tried, not
  maxima, and the placement is not monotonic with the period (8 x 16 with 3 stages missed
  timing at 4.4 ns and met it at 4.7 ns).
- No `almost_full` or `almost_empty` flags.
- Formal proofs are not done.
- The mutation check covers 10 mutants. It is not a proof of completeness.

## 12. References

- `docs/CONVENTIONS.md`, sections 3 to 6, 10.
- `ip/sync_fifo/spec/SPEC.md`: the single-clock reference.