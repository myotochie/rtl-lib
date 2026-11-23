.RECIPEPREFIX = >
IPS := sync_fifo async_fifo uart crc
.PHONY: check structure lint sim mutation
check: structure lint
structure:
> python3 scripts/check_structure.py
lint:
> @mkdir -p build/lint
> @for ip in $(IPS); do \
>   ghdl -i --std=08 --workdir=build/lint ip/$$ip/rtl/*.vhd && \
>   ghdl -m --std=08 --workdir=build/lint $$ip || exit 1; \
> done; echo "lint: VHDL OK"
sim:
> @for ip in $(IPS); do python3 scripts/run_sim.py $$ip || exit 1; done
mutation:
> @for ip in async_fifo uart crc; do python3 scripts/mutation_check.py $$ip || exit 1; done