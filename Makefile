# AXI4 CDC bridge: build, regression and synthesis.
#
# `make test` runs the directed suite, `make regress` runs the constrained-random
# regression and reports coverage as the union across seeds. Correctness is decided by
# the scoreboard and the protocol checkers; nothing here depends on reading a waveform.

VERILATOR ?= verilator
YOSYS     ?= yosys
PYTHON    ?= python3

RTL   := rtl/async_fifo.v rtl/axi4_slave.v rtl/cdc_bridge.v
TB    := tb/tb_cdc.sv
BUILD := build
SIM   := obj_dir/simv

VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD

SEEDS ?= 100
NTXN  ?= 400

DIRECTED := smoke error_response regfile fifo_full back_to_back

.PHONY: all sim test regress synth lint clean

all: test

$(BUILD):
	@mkdir -p $(BUILD)

# ---- elaborate
sim: $(SIM)
$(SIM): $(RTL) $(TB)
	$(VERILATOR) $(VFLAGS) --top-module tb_cdc -o simv $(RTL) $(TB)

# ---- directed tests
test: $(SIM)
	@fail=0; \
	for t in $(DIRECTED); do \
	  printf '%-16s ' $$t; \
	  if ./$(SIM) +test=$$t +seed=1 2>&1 | grep -q '=== RESULT: PASS ==='; then \
	    echo PASS; \
	  else \
	    echo FAIL; fail=1; \
	  fi; \
	done; \
	exit $$fail

# ---- constrained-random regression with cross-seed coverage
regress: $(SIM)
	$(PYTHON) scripts/regress.py $(SEEDS) $(NTXN)

# ---- area
synth: | $(BUILD)
	$(YOSYS) -q scripts/synth.ys
	@echo "--- cell counts ---"
	@grep -H "Number of cells" $(BUILD)/synth_*.txt

lint:
	$(VERILATOR) --lint-only -Wall $(RTL) --top-module cdc_bridge

clean:
	rm -rf $(BUILD) obj_dir
