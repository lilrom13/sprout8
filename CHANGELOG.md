# Changelog

All notable changes to the Sprout-8 ISA, the design and tools. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic
versioning, where a major version change means an ISA change visible to software.

## [Unreleased]

### Added
- Module specification and one guide per module, for building the CPU in Logisim
  (`docs/spec/sprout8-module-spec.md`, `docs/modules/`).
- The CPU as a Logisim-evolution project, `hw/logisim/sprout8.circ` (`pc` so far).
- `tools/logisim2vhdl.py`: headless VHDL export of a Logisim circuit.
- `tools/hex2logisim.py` and `tools/gen_logisim_vectors.py`: memory images and test vectors
  for Logisim.

### Changed
- The Logisim project is the design. The test runner exports each testbench's circuits to
  VHDL and runs the testbench on them; a circuit not drawn yet is reported as *missing*
  and does not fail CI (releases require every circuit). The manifest names the circuits
  instead of RTL files, and `hw/rtl/` holds only `sprout8_pkg.vhd`.
- The mutation check plants bugs in the Logisim drawing, generated from its components,
  instead of a fixed list of RTL edits.
- CI, nightly and release workflows install Java and the pinned Logisim-evolution 5.0.0.

## [0.1.0] - 2026-10-21

### Added
- Sprout-8 Instruction Set Manual v1.0-draft (`docs/spec/`).
- Reference multi-cycle RTL in VHDL-2008 (`hw/rtl/`).
- Self-checking testbenches for every unit and the full CPU, with a golden-model
  lockstep check (`hw/tb/`).
- Python emulator and example programs (`sw/`).
- Test runner, HTML/JUnit reports and mutation check (`tools/`).
- CI on GitHub Actions: lint, testbenches, mutation check, Pages report, nightly stress,
  tagged releases.
