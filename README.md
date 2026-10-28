# rtl-lib

![ci](https://github.com/myotochie/rtl-lib/actions/workflows/ci.yml/badge.svg)

A library of verified, parameterizable, versioned RTL IP blocks written in VHDL-2008.

Every IP follows the same lifecycle: **spec → architecture → RTL → verification → measured PPA → limits**.
Nothing is merged without a written spec, a passing testbench and a results folder.

## Status

| IP | Spec | RTL | Verification | Results | Version |
|---|---|---|---|---|---|
| `sync_fifo` | v0.1 | VHDL | simulated, 3 configurations | `sim_summary.txt`, `synth_summary.txt` | 0.2.0 |

Current release: `v0.2.0` (conventions, template, and `sync_fifo`: specification, VHDL RTL, testbench, simulation and synthesis results).
Next: formal proofs of `sync_fifo`.

## Repository layout

```
rtl-lib/
├── ip/<ip_name>/
│   ├── spec/      # written before any RTL
│   ├── rtl/       # synthesizable VHDL-2008 code
│   ├── tb/        # testbenches
│   ├── formal/    # assertions and formal proofs
│   └── results/   # coverage, fmax, area, power, with the script that produced them
├── templates/ip_template/   # copy this folder to start a new IP
├── docs/CONVENTIONS.md      # naming, reset, handshake, style
├── scripts/                 # check_structure.py, run_sim.py, synth_vivado.tcl
└── .github/workflows/ci.yml
```

## Quick start (Windows, Linux, macOS)

Requirements: Python 3 and [GHDL](https://github.com/ghdl/ghdl/releases) in the `PATH`.

```
python scripts/check_structure.py     # folder layout check
python scripts/run_sim.py sync_fifo   # compile and simulate (3 configurations)
```

On Linux or macOS (or WSL2), `make check` and `make sim` do the same.

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