## What does this change?

<!-- One or two sentences. Link the issue: "Fixes #12". -->

## Kind of change

- [ ] RTL (reference implementation)
- [ ] Testbench / verification
- [ ] ISA specification (`docs/spec/`) — behaviour visible to software
- [ ] Tooling, CI or docs

## Checklist

- [ ] `make ci` passes locally (lint, emulator tests, all testbenches)
- [ ] New behaviour has a check in a testbench (and in `sw/emulator/test_sprout8.py` if it is ISA-visible)
- [ ] If this fixes a bug the tests missed: a mutation for it is added to `tools/mutation_check.py`
- [ ] If the ISA changed: the manual, the golden model (`hw/tb/sprout8_iss_pkg.vhd`), the emulator and `CHANGELOG.md` are updated together
