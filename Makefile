# Sprout-8 developer commands. Everything CI runs is available here.
#   make test            run all testbenches
#   make test TB=tb_alu  run one testbench
#   make nightly         long random stress (SEED=... to reproduce a nightly run)
#   make mutation        plant bugs and check the testbenches catch them
#   make report          build build/report/index.html from the last run
#   make lint            GHDL strict compile (warnings are errors)
#   make emu-test        Python emulator unit tests
#   make wave TB=tb_cpu  dump a waveform (build/waves/tb_cpu.ghw) for GTKWave
#   make ci              what the CI test job runs
#   make logisim         Logisim memory images and test vectors -> build/logisim/
#   make logisim-tb TB=tb_pc   export a Logisim circuit to VHDL and run its testbench

GHDL    ?= ghdl
PYTHON  ?= python3
OUT     ?= build/report
SEED    ?= 2026
TB      ?=
ONLY    := $(if $(TB),--only $(TB),)

VHDL_FILES := $(shell $(PYTHON) -c "import json;m=json.load(open('hw/manifest.json'));print(' '.join(m['rtl']+m['tb_support']+[t['file'] for t in m['testbenches']]))")
LINT_WORK  := build/lint

.PHONY: test nightly mutation report lint emu-test wave ci logisim logisim-tb clean

test:
	$(PYTHON) tools/run_tests.py --ghdl $(GHDL) --out $(OUT) $(ONLY)

nightly:
	$(PYTHON) tools/run_tests.py --ghdl $(GHDL) --out $(OUT) --profile nightly -g tb_cpu.RAND_SEED=$(SEED) $(ONLY)

mutation:
	$(PYTHON) tools/mutation_check.py --ghdl $(GHDL) --out $(OUT)

report:
	$(PYTHON) tools/report.py $(OUT)

lint:
	rm -rf $(LINT_WORK) && mkdir -p $(LINT_WORK)
	$(GHDL) -a --std=08 --workdir=$(LINT_WORK) -Wall -Wno-delayed-checks --warn-error $(VHDL_FILES)
	@echo "lint: OK"

emu-test:
	cd sw/emulator && $(PYTHON) -m unittest -v

wave:
	@test -n "$(TB)" || (echo "usage: make wave TB=tb_cpu" && exit 2)
	$(PYTHON) tools/run_tests.py --ghdl $(GHDL) --out build/wave-run --only $(TB) --waves always
	mkdir -p build/waves && cp build/wave-run/waves/$(TB).ghw build/waves/
	@echo "open build/waves/$(TB).ghw in GTKWave"

ci: lint emu-test test report

logisim:
	$(PYTHON) tools/hex2logisim.py sw/programs/*.hex
	$(PYTHON) tools/gen_logisim_vectors.py

logisim-tb:
	@test -n "$(TB)" || (echo "usage: make logisim-tb TB=tb_pc" && exit 2)
	$(PYTHON) tools/logisim2vhdl.py $(patsubst tb_%,%,$(TB)) --test --ghdl $(GHDL)

clean:
	rm -rf build
