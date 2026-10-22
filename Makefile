# Sprout-8 developer commands. Everything CI runs is available here.
# The design is the Logisim project hw/logisim/sprout8.circ: the testbenches run on its
# circuits, exported to VHDL. Needs GHDL and Logisim-evolution (LOGISIM=launcher or .jar).
#   make test            run all testbenches (circuits not drawn yet are reported as missing)
#   make test TB=tb_alu  run one testbench
#   make nightly         long random stress (SEED=... to reproduce a nightly run)
#   make mutation        plant bugs and check the testbenches catch them
#   make report          build build/report/index.html from the last run
#   make lint            GHDL strict compile of the packages (warnings are errors)
#   make emu-test        Python emulator unit tests
#   make wave TB=tb_cpu  dump a waveform (build/waves/tb_cpu.ghw) for GTKWave
#   make ci              what the CI test job runs
#   make logisim         Logisim memory images and test vectors -> build/logisim/
#   make vhdl C=pc       export one Logisim circuit to VHDL -> build/logisim/vhdl/pc/

GHDL    ?= ghdl
PYTHON  ?= python3
OUT     ?= build/report
SEED    ?= 2026
TB      ?=
C       ?=
LOGISIM ?=
ONLY    := $(if $(TB),--only $(TB),)
LS      := $(if $(LOGISIM),--logisim $(LOGISIM),)

# the testbenches themselves need the exported design, so they are compiled by `make test`
VHDL_FILES := $(shell $(PYTHON) -c "import json;m=json.load(open('hw/manifest.json'));print(' '.join(m['packages']+m['tb_support']))")
LINT_WORK  := build/lint

.PHONY: test nightly mutation report lint emu-test wave ci logisim vhdl clean

test:
	$(PYTHON) tools/run_tests.py --ghdl $(GHDL) $(LS) --out $(OUT) $(ONLY)

nightly:
	$(PYTHON) tools/run_tests.py --ghdl $(GHDL) $(LS) --out $(OUT) --profile nightly -g tb_cpu.RAND_SEED=$(SEED) $(ONLY)

mutation:
	$(PYTHON) tools/mutation_check.py --ghdl $(GHDL) $(LS) --out $(OUT)

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
	$(PYTHON) tools/run_tests.py --ghdl $(GHDL) $(LS) --out build/wave-run --only $(TB) --waves always
	mkdir -p build/waves && cp build/wave-run/waves/$(TB).ghw build/waves/
	@echo "open build/waves/$(TB).ghw in GTKWave"

ci: lint emu-test test report

logisim:
	$(PYTHON) tools/hex2logisim.py sw/programs/*.hex
	$(PYTHON) tools/gen_logisim_vectors.py

vhdl:
	@test -n "$(C)" || (echo "usage: make vhdl C=pc" && exit 2)
	$(PYTHON) tools/logisim2vhdl.py $(LS) $(C)

clean:
	rm -rf build
