# Contributing to Sprout-8

## Setup

You need [GHDL](https://github.com/ghdl/ghdl) (CI pins **v5.1.1**, mcode backend),
[Logisim-evolution](https://github.com/logisim-evolution/logisim-evolution) (CI pins
**5.0.0**), Python 3.10+ and `make`. GTKWave is optional, for waveforms. If Logisim is not on
`PATH` or in `/opt/logisim-evolution`, set `LOGISIM` to its launcher or release `.jar`.

The design is `hw/logisim/sprout8.circ`. Edit it in Logisim; `make test` exports each circuit
to VHDL and runs its testbench. A `.circ` diff is not readable, so a reviewer relies on the
test results and on a screenshot of the changed circuit in the pull request.

```sh
make ci          # what CI runs: lint, emulator tests, all testbenches, report
make test TB=tb_cpu
make vhdl C=pc             # the VHDL Logisim generates for one circuit, in build/logisim/vhdl/pc/
make wave TB=tb_cpu        # then open build/waves/tb_cpu.ghw in GTKWave
open build/report/index.html
```

## Workflow

1. Branch from `main`, make the change, run `make ci`.
2. Open a pull request. CI must pass on the pinned GHDL. The run on the latest GHDL is
   advisory: if only that one fails, mention it in the PR.
3. The CI job summary shows the test table. The full HTML report, logs and the waveform of
   any failing testbench are in the run's artifacts.

## Rules of the road

- **The manual is the source of truth.** An ISA-visible change updates, in the same PR:
  `docs/spec/sprout8-isa-manual.md`, the golden model `hw/tb/sprout8_iss_pkg.vhd`, the
  emulator `sw/emulator/sprout8.py`, the tests, and `CHANGELOG.md`.
- **Every bug fix gets a test.** If the suite missed a bug of a kind the mutation check
  does not plant yet, teach `mutants_of()` in `tools/mutation_check.py` to plant it, so the
  gap stays closed.
- **Label every pin.** Pin labels become the VHDL port names the testbenches use; the export
  refuses a circuit with an unlabelled pin.
- **VHDL-2008 only.** No VHDL-2019 constructs; `make lint` treats warnings as errors.
- **Testbenches stay self-checking.** Use the `tb_pkg` checks and finish with `end_test`,
  so a failure gives a non-zero exit code.

## Adding a testbench

1. Create `hw/tb/tb_<name>.vhd` using `tb_pkg` (see `tb_flags.vhd` for the smallest example).
2. Add it to `hw/manifest.json` with the `circuits` it tests, a `unit` name and a `timeout_s`.
3. `make test TB=tb_<name>`. The runner, report and CI pick it up automatically.

## Reproducing a nightly failure

The nightly issue names the seed. Run `make nightly SEED=<seed>`.

## Releases

Update `CHANGELOG.md`, then tag: `git tag v1.0.0 && git push origin v1.0.0`. The release
workflow reruns the full verification and publishes the release only if it passes.

## Repository settings (one-time, by a maintainer)

- **Pages:** Settings → Pages → Source: *GitHub Actions*, then set the repository variable
  `PAGES_ENABLED` to `true` (Settings → Secrets and variables → Actions → Variables).
  Without it CI skips publishing the report (Pages needs a public repo or a paid plan).
- **Branch protection on `main`:** require a pull request and the status checks
  `Lint` and `Testbenches (GHDL v5.1.1)`.
- Optionally create a `nightly` label for the nightly failure issues.
