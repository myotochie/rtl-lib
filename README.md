# rtl-lib

![ci](https://github.com/myotochie/rtl-lib/actions/workflows/ci.yml/badge.svg)

A library of verified, parameterizable, versioned RTL IP blocks written in VHDL-2008 and SystemVerilog.

Every IP follows the same lifecycle: **spec → architecture → RTL → verification → measured PPA → limits**.
Nothing is merged without a written spec, a passing testbench and a results folder.

## Status

| IP | Spec | RTL | Verification | Results | Version |
|---|---|---|---|---|---|
| `sync_fifo` | draft | - | - | - | - |

Current release: `v0.1.0` (conventions and repository skeleton only, no RTL yet).

## Repository layout

```
rtl-lib/
├── ip/<ip_name>/
│   ├── spec/      # written before any RTL
│   ├── rtl/       # synthesizable code (VHDL-2008 and/or SystemVerilog)
│   ├── tb/        # testbenches
│   ├── formal/    # assertions and formal proofs
│   └── results/   # coverage, fmax, area, power, with the script that produced them
├── templates/ip_template/   # copy this folder to start a new IP
├── docs/CONVENTIONS.md      # naming, reset, handshake, style
├── scripts/check_structure.py
└── .github/workflows/ci.yml
```

## Quick start (Windows)

Use WSL2 with Ubuntu, then:

```bash
sudo apt install ghdl verilator make python3
make check      # structure check + lint
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
