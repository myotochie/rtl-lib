# crc

Parameterizable CRC engine (Rocksoft model): any width from 3 to 64 bits, any polynomial, 1 to 64 data bits per clock cycle, no stall. Version 0.5.0.

- Specification: [`spec/SPEC.md`](spec/SPEC.md)
- RTL: `rtl/crc_pkg.vhd`, `rtl/crc.vhd` (VHDL-2008)
- Testbench: `tb/crc_tb.vhd`, reference model `model/crc_model.py`
- Results: `results/`

## Usage

```vhdl
u_crc32 : entity work.crc
  generic map (CRC_WIDTH => 32, DATA_WIDTH => 8,
               POLY => "04C11DB7", INIT => "FFFFFFFF", XOROUT => "FFFFFFFF",
               REFIN => true, REFOUT => true)          -- CRC-32/ISO-HDLC (Ethernet, zip)
  port map (clk_i => clk, rst_n_i => rst_n,
            clear_i => clear, valid_i => valid, start_i => start,
            data_i => data, crc_o => crc);
```

Send the first word with `start_i = 1` (or pulse `clear_i` before the message), then one word per cycle with `valid_i = 1`. `crc_o` is the CRC of the words accepted so far, one cycle after each word.

Generics of common algorithms:

| Algorithm | `CRC_WIDTH` | `POLY` | `INIT` | `XOROUT` | `REFIN` | `REFOUT` |
|---|---|---|---|---|---|---|
| CRC-32/ISO-HDLC | 32 | 04C11DB7 | FFFFFFFF | FFFFFFFF | true | true |
| CRC-32/ISCSI | 32 | 1EDC6F41 | FFFFFFFF | FFFFFFFF | true | true |
| CRC-16/IBM-3740 | 16 | 1021 | FFFF | 0000 | false | false |
| CRC-16/MODBUS | 16 | 8005 | FFFF | 0000 | true | true |
| CRC-8/SMBUS | 8 | 07 | 00 | 00 | false | false |

## Reproduce the results

From the repository root:

```
python ip/crc/model/crc_model.py
python scripts/run_sim.py crc
python scripts/mutation_check.py crc
```

Synthesis (Vivado 2023.1, cmd after `settings64.bat`):

```
vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_crc.tcl -tclargs CRC-32/ISO-HDLC 32 4.0
```

## Status

Simulation: 39 configurations and 10 illegal values. Mutation check: 18 of 18 caught. Formal: not yet (see SPEC section 10).