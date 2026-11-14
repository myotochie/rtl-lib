# rtl-lib

![ci](https://github.com/myotochie/rtl-lib/actions/workflows/ci.yml/badge.svg)

A library of verified, parameterizable, versioned RTL IP blocks written in VHDL-2008.

Every IP follows the same lifecycle: **spec → architecture → RTL → verification → measured PPA → limits**.
Nothing is merged without a written spec, a passing testbench and a results folder.

## Status

| IP | Spec | RTL | Verification | Results | Version |
|---|---|---|---|---|---|
| `sync_fifo` | v0.1 | VHDL | simulated, 3 configurations | `sim_summary.txt`, `synth_summary.txt` | 0.2.0 |
| `async_fifo` | v0.3 | VHDL | simulated, 24 clock/phase configurations, 10 mutants | `sim_summary.txt`, `mutation_summary.txt`, `synth_summary.txt` | 0.3.0 |
| `uart` | v0.4 | VHDL | simulated, 10 configurations with fault injection, 19 mutants | `sim_summary.txt`, `mutation_summary.txt`, `model_summary.txt`, `synth_summary.txt` | 0.4.0 |

Current release: `v0.4.0` (adds `uart`: transmitter, receiver and top level, with specification, testbench, mutation check, receiver model and synthesis results).
Next: formal proofs of the FIFOs and of `uart`.

## Repository layout

```
rtl-lib/
├── ip/<ip_name>/
│   ├── spec/      # written before any RTL
│   ├── rtl/       # synthesizable VHDL-2008 code
│   ├── tb/        # testbenches
│   ├── formal/    # assertions and formal proofs
│   ├── model/     # reference models used to validate design choices (some IPs)
│   └── results/   # simulation, mutation, fmax and area, with the command that produced them
├── templates/ip_template/   # copy this folder to start a new IP
├── docs/CONVENTIONS.md      # naming, reset, handshake, style, definition of done
├── scripts/                 # check_structure.py, run_sim.py, mutation_check.py, synth_vivado_*.tcl
└── .github/workflows/ci.yml
```

## Quick start (Windows, Linux, macOS)

Requirements: Python 3 and [GHDL](https://github.com/ghdl/ghdl/releases) in the `PATH`.

```
python scripts/check_structure.py       # folder layout check
python scripts/run_sim.py sync_fifo     # compile and simulate (3 configurations)
python scripts/run_sim.py async_fifo    # 24 clock/phase configurations, about 100 s
python scripts/mutation_check.py async_fifo   # 10 injected bugs, all must be caught
python scripts/run_sim.py uart          # 10 configurations and 8 illegal parameter tests
python scripts/mutation_check.py uart   # 19 injected bugs, all must be caught
```

On Linux or macOS (or WSL2), `make check`, `make sim` and `make mutation` do the same for all IPs.

Synthesis results come from Vivado 2023.1 (out of context, `xc7z010clg400-1`):

```
vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_async.tcl -tclargs 32 1024 2
vivado -mode batch -nolog -nojournal -source scripts/synth_vivado_uart.tcl -tclargs uart 100000000 115200 8 0 1
```

## Starting a new IP

```bash
cp -r templates/ip_template ip/<ip_name>
# then fill in ip/<ip_name>/spec/SPEC.md before writing any RTL
make check
```

## Conventions

See [docs/CONVENTIONS.md](docs/CONVENTIONS.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).

## Contributing

Pull requests and issues are used even on solo work, so the history reads like a team's.
A pull request must keep `make check` green.