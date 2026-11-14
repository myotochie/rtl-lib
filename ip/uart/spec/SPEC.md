# uart: specification

Version: 0.4.0
Status: frozen for 0.4.0

## 1. Summary

`uart` is an asynchronous serial transmitter and receiver (UART) with valid/ready
streams on the parallel side. It is made of three entities:

- `uart_tx`: transmitter;
- `uart_rx`: receiver;
- `uart`: top level that instantiates both, with the ports of both.

Format, baud rate and clock frequency are generics. There is no FIFO inside: the
IP has one word of storage on the receive side and none on the transmit side. A
FIFO from this library can be put in front of or behind it.

Frame (line idles high):

    idle ... | start (0) | D0 (LSB first) ... D(DATA_BITS-1) | parity (optional) | stop (1) [stop (1)] | next frame or idle

## 2. Parameters

| Generic | Type | Default | Legal values | Meaning |
|---|---|---|---|---|
| CLK_FREQ_HZ | positive | 100_000_000 | 1 to 500_000_000 | clock frequency of `clk_i` |
| BAUD | positive | 115_200 | see below | bit rate in bit/s |
| DATA_BITS | positive | 8 | 5 to 8 | data bits per frame |
| PARITY | natural | 0 | 0 none, 1 even, 2 odd | parity bit |
| STOP_BITS | positive | 1 | 1 or 2 | stop bits sent; stop bits checked by the receiver |

Derived constant (in `uart_pkg`): `BIT_CLKS = round(CLK_FREQ_HZ / BAUD)`, number of
clock cycles per bit, rounded to nearest.

Legality, checked by elaboration assertions (CONVENTIONS section 6):

- `16 <= BIT_CLKS <= 65535`;
- the rounding error `|BIT_CLKS * BAUD / CLK_FREQ_HZ - 1|` is at most 2 %;
- the other generics in the ranges above.

An illegal value stops the simulation or synthesis with a message that starts with
`uart: `.

Even parity: the parity bit makes the number of ones among data bits and parity
bit even. Odd parity: odd.

## 3. Ports

All ports use `std_logic` or `std_logic_vector`. One clock, one reset.

| Port | Dir | Width | Description |
|---|---|---|---|
| clk_i | in | 1 | clock, rising edge |
| rst_n_i | in | 1 | synchronous reset, active low |
| tx_valid_i | in | 1 | transmit stream: word available |
| tx_ready_o | out | 1 | transmit stream: word accepted if valid and ready at the same edge |
| tx_data_i | in | DATA_BITS | word to send |
| txd_o | out | 1 | serial output, registered, idles high |
| rxd_i | in | 1 | serial input, asynchronous to `clk_i` |
| rx_valid_o | out | 1 | receive stream: word available |
| rx_ready_i | in | 1 | receive stream: word accepted if valid and ready at the same edge |
| rx_data_o | out | DATA_BITS | received word |
| rx_parity_err_o | out | 1 | parity error on this word, aligned with `rx_valid_o` |
| rx_frame_err_o | out | 1 | a stop bit was low in this word, aligned with `rx_valid_o` |
| rx_overrun_o | out | 1 | one-cycle pulse: a received word was dropped |

`uart_tx` has `clk_i, rst_n_i, tx_*, txd_o`. `uart_rx` has `clk_i, rst_n_i, rxd_i, rx_*`.
All three entities have the same five generics, with the same names and defaults.
Port names and widths are identical in all three entities.

## 4. Protocol

Both streams follow the valid/ready rules of CONVENTIONS section 4:

- a transfer happens at a rising edge where valid and ready are both 1;
- `tx_ready_o` does not depend combinationally on `tx_valid_i`;
- `rx_valid_o` does not depend combinationally on `rx_ready_i`;
- once `rx_valid_o` is 1, `rx_data_o`, `rx_parity_err_o` and `rx_frame_err_o` do
  not change until the transfer.

`rx_overrun_o` is not part of the stream: it is a status pulse.

## 5. Behavior

### 5.1 Transmitter

- After reset, `txd_o` is 1.
- `tx_ready_o` is 1 when the transmitter is idle, and also during the last clock
  cycle of the last stop bit. A word accepted in that last cycle starts at the next
  edge with no gap, so frames can follow each other with no idle time.
- At the edge of a transfer, the word is loaded and `txd_o` becomes 0 (start bit)
  at that same edge. Each bit then lasts exactly `BIT_CLKS` clock cycles.
- The frame lasts exactly `(1 + DATA_BITS + P + STOP_BITS) * BIT_CLKS` cycles, with
  P = 1 if PARITY is not 0, else 0. Every line transition is at a multiple of
  `BIT_CLKS` cycles after the start edge.
- With no new word, `txd_o` returns to 1 and stays there.
- Latency from transfer to the line going low: 0 cycles (same edge).

### 5.2 Receiver

- `rxd_i` goes through a two-flip-flop synchronizer. No other filtering of the
  input.
- Idle: a falling edge on the synchronized input starts a frame. Let m0 be the
  cycle where it is seen. The receiver restarts its bit counter at m0, so the two
  synchronizer cycles cancel out.
- Each bit k (start = 0, then data, parity, stops) is decided by a **majority of
  three samples** of the synchronized input at cycles
  `m0 + k*BIT_CLKS + BIT_CLKS/2 + {-S, 0, +S}`, with `S = max(1, BIT_CLKS/16)`
  (integer division).
- Start check: if the start bit decides 1 (false start), the receiver goes back to
  idle with no word and no flag.
- Data bits are collected LSB first. Parity is checked if PARITY is not 0. All stop
  bits are checked: if any decides 0, `rx_frame_err_o` is set for this word.
- After the last stop-bit decision, the receiver returns to idle immediately (about
  0.56 bit into the last stop bit), so that back-to-back frames work.
- A new frame starts only on a falling edge. If the line stays low after a framing
  error (break), the receiver waits for the line to go high first.
- The word is delivered with its flags, also when a flag is set. The data of a
  frame with a framing error is whatever was sampled.
- A break (line low for a whole frame) appears as a word of all zeros with
  `rx_frame_err_o` = 1. It is not distinguished from a zero word with a low stop
  bit. With odd parity, `rx_parity_err_o` is also 1.

### 5.3 Receive buffer and overrun

- The receiver has one output register. When a frame ends and the register is
  empty (or is accepted at that same edge), the word, `rx_parity_err_o` and
  `rx_frame_err_o` are loaded and `rx_valid_o` is 1 on the next cycle.
- If the register still holds a word that was not accepted, the new word is
  dropped, the old word stays unchanged, and `rx_overrun_o` is 1 for one cycle
  (the cycle after the drop).
- A consumer must accept a word within about one frame time minus the time to the
  last stop-bit decision to avoid an overrun at full line rate.

### 5.4 Reset

- `rst_n_i` low, sampled at a rising edge: transmitter idle, `txd_o` = 1,
  `tx_ready_o` = 0; receiver idle, `rx_valid_o` = 0, `rx_overrun_o` = 0. A frame in
  progress is abandoned.
- The receiver synchronizer flops are reset to **0**, not 1. A line that is low at
  reset release is therefore not taken for a start bit: the receiver waits for the
  line to go high first. In the normal case (line idle high) the receiver is ready
  3 cycles after reset release.
- `tx_ready_o` is 0 during reset and rises 1 cycle after reset release.

## 6. Corner cases

| Case | Behavior |
|---|---|
| Baud mismatch between sender and receiver | Frames are correct if the total mismatch (sender error + receiver rounding error) is within ±2 % for every supported format. Measured limits of the model are larger (section 9). |
| Glitch on `rxd_i` of at most S cycles inside a frame | Corrected by the majority vote, the word is correct. |
| Low glitch in idle of at most half a bit | Ignored: no word, no flag. |
| Low glitch in idle longer than half a bit | Accepted as a start: the frame is sampled and reported (data from the line, likely a framing error). |
| Glitch of 1 cycle between BIT_CLKS/2 - S and BIT_CLKS/2 + S cycles before a real start | The following frame can be lost or corrupted. Known limit (section 11). |
| Stop bit low | Word delivered with `rx_frame_err_o` = 1. |
| Parity wrong | Word delivered with `rx_parity_err_o` = 1. |
| Consumer does not accept a word | Next complete word is dropped, `rx_overrun_o` pulses (5.3). |
| `tx_valid_i` held high | Frames go out back to back with no gap, each exactly the frame length. |
| `tx_data_i` changes while `tx_valid_i` is high and `tx_ready_o` is 0 | Allowed: the word is read only at the transfer edge. |
| Reset during a frame | Frame abandoned (5.4), no flag, no partial word. |
| Line stuck low | One word with `rx_frame_err_o` = 1, then nothing until the line goes high. |

## 7. Architecture

- `uart_pkg`: `clog2`, `BIT_CLKS` computation and legality checks as functions,
  parity function, vote offset.
- `uart_tx`: busy flag, bit counter 0 to `BIT_CLKS-1`, bit index, shift register
  loaded at the transfer (data, parity, stop bits), registered `txd_o`, a `run_q`
  flag that keeps `tx_ready_o` low during and one cycle after reset.
- `uart_rx`: synchronizer (two flops, `ASYNC_REG`), falling-edge detector on the
  synchronized signal, bit counter restarted at the edge, two sample registers
  (first and middle sample) and the third sample read directly at the decision
  cycle, shift register, parity accumulator, frame error flag, one output register.
- No FIFO, no clock divider shared between sender and receiver: each side has its
  own counter, so there is no tick to distribute.
- Counters are `clog2(BIT_CLKS)` bits wide.

## 8. Target metrics

Target part: Xilinx 7 series, `xc7z010clg400-1`, Vivado 2023.1, out of context,
4.0 ns clock (250 MHz). Targets: timing met at 250 MHz, no BRAM, no DSP.

Measured values (command in section 9, item 8), to be filled:

| Entity | CLK / BAUD / format | LUT | FF | Timing at 4.0 ns |
|---|---|---|---|---|
| uart | 100 MHz, 115200, 8N1 | | | |
| uart_tx | 100 MHz, 115200, 8N1 | | | |
| uart_rx | 100 MHz, 115200, 8N1 | | | |
| uart | 100 MHz, 6.25 Mbaud (BIT_CLKS 16), 8E2 | | | |

## 9. Verification plan and results

Self-checking testbench `uart_tb` (GHDL, VHDL-2008), run by
`python scripts/run_sim.py uart`. It prints `TEST PASSED` only if every check
passes. Coverage items fail the test if never hit.

1. **Loopback** of the top level, random words in three phases (full rate, random
   gaps, one idle time per word). A monitor checks the transmitted line cycle by
   cycle: start bit at the transfer edge, every transition on a multiple of
   `BIT_CLKS`, every bit at its middle, frame length, `tx_ready_o` timing (no gap at
   full rate). A consumer checks every received word and that no flag or overrun
   occurs.
2. **Receiver against a line model** in the testbench, which can change the bit time
   and inject faults:
   - baud mismatch +2 %, −2 % (back to back, random phase) and 0 % with random gaps;
   - parity error, framing error on each stop bit, break and recovery;
   - 54 directed glitches of 1 and S cycles, on and around the three vote samples of
     the start bit, the first data bit and the last stop bit: all removed by the vote;
   - sample position: each bit valid only in its middle 40 %;
   - low glitches in idle shorter than half a bit: no word;
   - consumer stall: overrun pulses, first word kept, dropped words never come out;
   - reset in the middle of a frame, with a pending word, and with the line low.
3. **Stream rules**: valid, data and flags hold until the transfer on both receive
   outputs.
4. **Configurations** (100 MHz unless noted): `BIT_CLKS` 16 (8N1, 8E2, 5N1), 20
   (8E1), 33 (8O2), 100 (7E2, 8O1, 6N2); 48 MHz at 115200 (`BIT_CLKS` 417) and
   100 MHz at 115200 (868).
5. **Negative tests**: 8 illegal generic values are rejected with the expected message.
6. **Mutation check**: 19 injected bugs, all caught
   (`python scripts/mutation_check.py uart`, result in `results/mutation_summary.txt`).
7. **Model**: the design choices were checked with a clock-level Python model of the
   receiver (`python ip/uart/model/uart_rx_model.py`, result in
   `results/model_summary.txt`). It is a model, not the RTL. Worst values over
   `BIT_CLKS` 16 to 868:

   | Format | Sender slower | Sender faster |
   |---|---|---|
   | 8N1 | +5.5 % | −3.75 % |
   | 8E2 | +5.0 % | −3.0 % |
   | 5N1 | +8.25 % | −5.25 % |

   The RTL testbench checks ±2 %; the larger limits are not promised.

## 8. Measured metrics

Part Xilinx 7 series `xc7z010clg400-1`, Vivado 2023.1, out of context, one clock.
Command and raw lines: `results/synth_summary.txt`. No BRAM, no DSP.

| Entity | CLK / BAUD / format | LUT | FF | Timing |
|---|---|---|---|---|
| uart | 100 MHz, 115200 (BIT_CLKS 868), 8N1 | 58 | 66 | met at 4.5 ns (242 MHz) |
| uart_tx | 100 MHz, 115200, 8N1 | 31 | 26 | met at 4.5 ns (240 MHz) |
| uart_rx | 100 MHz, 115200, 8N1 | 30 | 40 | met at 4.0 ns (287 MHz) |
| uart | 100 MHz, 6.25 Mbaud (BIT_CLKS 16), 8E2 | 46 | 58 | met at 4.0 ns (254 MHz) |

`uart` and `uart_tx` at 115200 baud did not meet 4.0 ns (WNS -0.005 ns and -0.140 ns),
so they are reported at 4.5 ns.

9. **Formal**: not done for this release. This is a documented exception and a
   GitHub issue is opened (CONVENTIONS section 10).

## 10. Integration requirements

- `rxd_i` must come directly from an input pin or from a flop in the `clk_i`
  domain; the two-flop synchronizer is inside `uart_rx`. Add no logic between the
  pin and `rxd_i`.
- The synchronizer flops carry `ASYNC_REG`. Constrain the path from the pin to the
  first synchronizer flop as an asynchronous input (`set_false_path -from` the pin,
  as in `scripts/synth_vivado_uart.tcl`). Do not constrain the pin to the clock
  edge.
- `CLK_FREQ_HZ` and `BAUD` must give a `BIT_CLKS` that meets section 2. The
  assertion fails at elaboration otherwise.
- The consumer must accept words in time (5.3), or add a FIFO behind `rx_*`.

## 11. Limits

- No hardware flow control (RTS/CTS), no 9-bit mode, no auto-baud.
- No FIFO: one word of receive buffer, no transmit buffer.
- A frame is lost or corrupted if a 1-cycle glitch arrives between
  `BIT_CLKS/2 - S` and `BIT_CLKS/2 + S` cycles before a real start (model: window
  of 1, 2 and 6 cycles for `BIT_CLKS` 16, 32 and 100). Not covered by the
  testbench.
- Break is not reported separately from a zero word with a framing error.
- Majority vote protects against glitches of up to S cycles, not more. Model, 8N1,
  glitch of S+1 cycles at a random position: 1.8 % of frames lost at `BIT_CLKS` 100.
- The 2 % limit on the `BIT_CLKS` rounding error rejects some pairs (CLK, BAUD):
  100 MHz at 6.1 Mbaud gives `BIT_CLKS` 16, error 2.4 %, rejected; 100 MHz at
  8 Mbaud gives 12, rejected.
- The receiver is ready only 3 cycles after reset release.
- No formal proof (section 9, item 9); the 19 mutants are not a proof either.
- Out-of-context synthesis figures do not include I/O effects.
- - `uart` and `uart_tx` at BIT_CLKS 868 do not meet 4.0 ns (250 MHz): `tx_ready_o` is a
  combinational function of the bit and frame counters. Timing is met at 4.5 ns.

## 12. Design decisions

- Majority vote of three samples rather than one: removes glitches of up to S
  cycles at the cost of two flops (model: single sample loses 1.7 to 7 % of frames
  with a 1 to S cycle glitch, vote loses none).
- ±2 % promised: the worst model limit is −3.0 % (8E2, `BIT_CLKS` 16); 1 % of margin.
- Word delivered with flags, not dropped: the software decides.
- Overrun drops the new word: a pending word is never corrupted.
- Synchronizer reset to 0: a low line at reset release is not a start bit.
- No FIFO: avoids a dependency between IPs; a FIFO of the library can be added.

## 13. References

- docs/CONVENTIONS.md, sections 4 (valid/ready), 6 (parameters), 10 (definition of done).
- Asynchronous serial frame format, as in common UART devices (for example
  16550-compatible frame layout).
- `ip/uart/results/`: `sim_summary.txt`, `mutation_summary.txt`, `model_summary.txt`,
  `synth_summary.txt` (to come).