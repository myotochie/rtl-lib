# Changelog

All notable changes to this repository are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses SemVer.

## [Unreleased]

## [0.3.0] - 2026-11-02

### Added
- `async_fifo`: dual-clock FIFO with Gray-coded pointers and `SYNC_STAGES` synchronizers (spec, VHDL RTL, two-clock testbench).
- `scripts/mutation_check.py` and `make mutation`: 10 injected bugs, all caught.
- `scripts/synth_vivado_async.tcl`: two-clock synthesis with a configurable clock period, crossing constraints, setup and hold check (TIMING=MET), ASYNC_REG check and CDC report.
- `docs/CONVENTIONS.md` section 10: definition of done.
- Mutation check step in the CI workflow.

### Changed
- The library is VHDL only: SystemVerilog references removed from the docs, Makefile and CI.
- `scripts/run_sim.py` takes any generics and checks that illegal parameters are rejected; `sync_fifo` results regenerated.

## [0.2.0] - 2026-10-25

### Added
- `sync_fifo` VHDL-2008 RTL (`sync_fifo.vhd`, `sync_fifo_pkg.vhd`).
- Self-checking testbench with reference queue, protocol assertions and coverage checks.
- `scripts/run_sim.py`: compiles and simulates an IP with GHDL on any OS.
- `make sim`, a simulation step in the CI workflow, and `scripts/synth_vivado.tcl` with the first area and fmax results for `sync_fifo`.

### Changed
- Lint now uses full GHDL analysis (`ghdl -a`) instead of a syntax-only check.
- README quick start no longer requires WSL2.

## [0.1.0] - 2026-10-20

### Added
- Repository skeleton: `ip/`, `templates/ip_template/`, `docs/`, `scripts/`.
- Conventions: lifecycle, naming, reset, valid/ready handshake, style, results, versioning.
- IP template with a specification model.
- `scripts/check_structure.py` and `make check` (structure check and lint).
- GitHub Actions workflow running `make check` on every push and pull request.
- IP folder `ip/sync_fifo/` with its full specification (no RTL yet).