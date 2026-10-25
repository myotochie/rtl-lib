.RECIPEPREFIX = >

VHDL_FILES   := $(shell find ip -path "*/rtl/*" \( -name "*.vhd" -o -name "*.vhdl" \) 2>/dev/null | sort)
VHDL_ORDERED := $(filter %_pkg.vhd,$(VHDL_FILES)) $(filter-out %_pkg.vhd,$(VHDL_FILES))
SV_FILES     := $(shell find ip -path "*/rtl/*" \( -name "*.sv" -o -name "*.v" \) 2>/dev/null | sort)

.PHONY: check structure lint sim

check: structure lint

structure:
> python3 scripts/check_structure.py

lint:
> @if [ -z "$(VHDL_FILES)" ]; then echo "lint: no VHDL files yet"; else mkdir -p build/lint && ghdl -a --std=08 --workdir=build/lint $(VHDL_ORDERED) && echo "lint: VHDL OK"; fi
> @if [ -z "$(SV_FILES)" ]; then echo "lint: no SystemVerilog files yet"; else for f in $(SV_FILES); do verilator --lint-only -Wall $$f || exit 1; done; fi

sim:
> python3 scripts/run_sim.py sync_fifo