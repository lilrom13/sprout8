# Changelog

All notable changes to the Sprout-8 ISA, reference RTL and tools. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic
versioning, where a major version change means an ISA change visible to software.

## [Unreleased]

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
