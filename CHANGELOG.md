# Changelog

All notable changes to this repository are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses SemVer.

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