# Changelog

All notable changes to this repository are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses SemVer.

## [0.1.0] - Unreleased

### Added
- Repository skeleton: `ip/`, `templates/ip_template/`, `docs/`, `scripts/`.
- Conventions: lifecycle, naming, reset, valid/ready handshake, style, results, versioning.
- IP template with a specification model.
- `scripts/check_structure.py` and `make check` (structure check and lint).
- GitHub Actions workflow running `make check` on every push and pull request.
- Draft IP folder `ip/sync_fifo/` (spec only, no RTL yet).
