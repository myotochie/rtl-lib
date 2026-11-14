# uart

Asynchronous serial transmitter and receiver, VHDL, valid/ready on the parallel side.

- Format: 5 to 8 data bits, none/even/odd parity, 1 or 2 stop bits.
- Baud rate set by generics `CLK_FREQ_HZ` and `BAUD` (`BIT_CLKS` from 16 to 65535, rounding error at most 2 %).
- Receiver: two-flop synchronizer, restart on the start edge, majority vote of three samples around the middle of each bit.
- Frame flags: parity error, framing error, overrun pulse. No FIFO.

Entities: `uart_tx`, `uart_rx`, `uart` (top).

Reproduce:

    python scripts/run_sim.py uart
    python scripts/mutation_check.py uart
    python ip/uart/model/uart_rx_model.py

Status: spec 0.4.0, RTL and testbench done, synthesis results to come.

Spec: [spec/SPEC.md](spec/SPEC.md)