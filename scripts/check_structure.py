#!/usr/bin/env python3
"""Check that every IP folder follows the rtl-lib layout."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED_DIRS = ("spec", "rtl", "tb", "formal", "results")
REQUIRED_FILES = ("README.md", "spec/SPEC.md")


def check_ip(ip_dir: Path) -> list[str]:
    errors = []
    for name in REQUIRED_DIRS:
        if not (ip_dir / name).is_dir():
            errors.append(f"{ip_dir.name}: missing folder '{name}/'")
    for name in REQUIRED_FILES:
        if not (ip_dir / name).is_file():
            errors.append(f"{ip_dir.name}: missing file '{name}'")
    return errors


def main() -> int:
    errors = []

    if not (ROOT / "templates" / "ip_template").is_dir():
        errors.append("missing templates/ip_template/")

    ip_root = ROOT / "ip"
    ips = sorted(p for p in ip_root.iterdir() if p.is_dir()) if ip_root.is_dir() else []

    for ip_dir in ips:
        errors.extend(check_ip(ip_dir))

    if errors:
        print("structure check FAILED:")
        for message in errors:
            print(f"  - {message}")
        return 1

    print(f"structure check OK ({len(ips)} IP folder(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
