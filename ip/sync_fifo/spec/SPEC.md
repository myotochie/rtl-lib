# sync_fifo: specification

**Status:** draft
**Version:** 0.0.0
**Languages:** VHDL-2008 / SystemVerilog

## 1. Summary

One paragraph: what the IP does and why it exists.

## 2. Parameters

| Name | Type | Default | Legal range | Meaning |
|---|---|---|---|---|
| | | | | |

## 3. Ports

| Name | Direction | Width | Clock domain | Description |
|---|---|---|---|---|
| `clk_i` | in | 1 | | Clock |
| `rst_n_i` | in | 1 | `clk_i` | Synchronous active-low reset |

## 4. Interfaces and protocol

Handshakes, timing diagrams, ordering rules. Follow `docs/CONVENTIONS.md`.

## 5. Behavior

Cycle-accurate description of normal operation.

## 6. Corner cases

| Case | Expected behavior |
|---|---|
| | |

## 7. Architecture

The chosen design, and the alternatives discarded with the reason.

## 8. Target metrics

| Metric | Target | Measured | Script |
|---|---|---|---|
| fmax | | | |
| Area | | | |
| Latency | | | |
| Throughput | | | |

## 9. Verification plan

| Feature | Check (assertion, scoreboard, proof) | Coverage item |
|---|---|---|
| | | |

## 10. Limits

What does not work, bugs found, planned next steps.

## 11. References
