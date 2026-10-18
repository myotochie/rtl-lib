VHDL_FILES := $(shell find ip -path "*/rtl/*" \( -name "*.vhd" -o -name "*.vhdl" \) 2>/dev/null)
SV_FILES   := $(shell find ip -path "*/rtl/*" \( -name "*.sv" -o -name "*.v" \) 2>/dev/null)

.PHONY: check structure lint

check: structure lint

structure:
	python3 scripts/check_structure.py

lint:
	@if [ -z "$(VHDL_FILES)" ]; then echo "lint: no VHDL files yet"; else ghdl -s --std=08 $(VHDL_FILES); fi
	@if [ -z "$(SV_FILES)" ]; then echo "lint: no SystemVerilog files yet"; else for f in $(SV_FILES); do verilator --lint-only -Wall $$f || exit 1; done; fi
