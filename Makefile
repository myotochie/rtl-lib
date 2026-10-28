.RECIPEPREFIX = >

VHDL_FILES   := $(shell find ip -path "*/rtl/*" \( -name "*.vhd" -o -name "*.vhdl" \) 2>/dev/null | sort)
VHDL_ORDERED := $(filter %_pkg.vhd,$(VHDL_FILES)) $(filter-out %_pkg.vhd,$(VHDL_FILES))

.PHONY: check structure lint sim

check: structure lint

structure:
> python3 scripts/check_structure.py

lint:
> @if [ -z "$(VHDL_FILES)" ]; then echo "lint: no VHDL files yet"; else mkdir -p build/lint && ghdl -a --std=08 --workdir=build/lint $(VHDL_ORDERED) && echo "lint: VHDL OK"; fi

sim:
> python3 scripts/run_sim.py sync_fifo