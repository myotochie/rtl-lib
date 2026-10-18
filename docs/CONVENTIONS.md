# Conventions

These rules apply to every IP in the library. A rule that is broken must be justified in the IP's spec.

## 1. Lifecycle

Each IP goes through six steps, and each step leaves a file in the repository:

| Step | Output | Location |
|---|---|---|
| Specification | `SPEC.md`: interfaces, corner cases, target metrics | `spec/` |
| Architecture | the chosen design and the alternatives discarded, one page | `spec/SPEC.md` |
| RTL | lint-clean synthesizable code | `rtl/` |
| Verification | testbench, assertions, coverage numbers | `tb/`, `formal/` |
| Measured PPA | fmax, area, power, with the script that produced them | `results/` |
| Limits | what does not work, bugs found, next steps | `spec/SPEC.md` |

The spec is written and reviewed before the RTL. A pull request that adds RTL without a spec is rejected.

## 2. Folder layout of an IP

```
ip/<ip_name>/
├── README.md
├── spec/SPEC.md
├── rtl/
├── tb/
├── formal/
└── results/
```

`make check` fails if an IP folder is missing one of these entries.

## 3. Naming

- Files, entities, modules and signals use `snake_case`. One module or entity per file, and the file name equals its name.
- Port suffixes: `_i` input, `_o` output, `_io` bidirectional.
- Active-low signals end with `_n` (before the port suffix): `rst_n_i`.
- Registered signal: `_q`. Next-state value: `_d`.
- Constants, generics and parameters use `UPPER_CASE`: `WIDTH`, `DEPTH`.
- Clock: `clk_i`. One clock per module unless the spec explains why.

## 4. Reset

- Default: synchronous, active-low reset `rst_n_i`.
- One reset per clock domain, synchronized outside the IP.
- An asynchronous reset is allowed only in reset synchronizers and must be stated in the spec.

## 5. Handshake (valid/ready)

- A transfer happens on a rising clock edge when `valid` and `ready` are both high.
- `valid` must not depend combinationally on `ready`.
- Once `valid` is high, it stays high and the data stays stable until the transfer happens.
- Ports are named `<channel>_valid_i/o`, `<channel>_ready_o/i`, `<channel>_data_i/o`.

## 6. Parameters

- Every parameter has a documented legal range in the spec.
- Illegal values are caught by an assertion at elaboration time.

## 7. Style and lint

- VHDL-2008 and SystemVerilog (IEEE 1800). No unintended latches.
- VHDL: `ghdl -s --std=08` must pass. SystemVerilog: `verilator --lint-only -Wall` must pass.
- Waivers are listed in the IP's spec with a reason.

## 8. Results

Every number in `results/` comes with the exact command that reproduces it, in the same folder.
A number without a reproduction command is not accepted.

## 9. Versioning

- The repository uses SemVer. Releases are tagged `vMAJOR.MINOR.PATCH`.
- Every release has an entry in `CHANGELOG.md`.
- The README status table is updated in the same pull request as the change it reports.
