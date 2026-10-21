# Logisim implementation: working notes

Running notes on the Logisim-evolution implementation in `sprout8.circ`: how it is tested, what was learned, and what is still open. Newest first within each section.

## Status

| Module | Logisim | Logisim test vectors | VHDL export + testbench |
| --- | --- | --- | --- |
| `pc` | done | `pc.txt`: 1,042 rows pass | `tb_pc`: PASS (517 checks) |
| others | not started | | |

## Testing a circuit against the VHDL testbenches

```sh
make logisim-tb TB=tb_pc          # = python3 tools/logisim2vhdl.py pc --test
```

`tools/logisim2vhdl.py` exports the circuit with Logisim's own HDL generator, then compiles `hw/rtl/sprout8_pkg.vhd`, the testbench support packages, the generated VHDL and `hw/tb/tb_<circuit>.vhd` with GHDL, and runs the testbench. Generated files go to `build/logisim/vhdl/<circuit>/`, GHDL's work library to `build/logisim/ghdl-work/`.

- **Headless export.** `logisim-evolution --test-fpga <circ> <circuit> <board> HDLONLY`. Logisim refuses to generate HDL until every pin is mapped to the FPGA board, even in HDL-only mode. The script adds a board map to a temporary copy of the project: inputs tied to constant 0 (`vconst`), outputs left open. This only affects Logisim's board wrapper (`toplevel/logisimTopLevelShell`), which the script discards. Format found in Logisim's `XmlReader.loadMap`: `<boardmap boardname="..."><mc key="/<pin label>" vconst="0"/>…`.
- **No files outside the repository.** By default Logisim writes to `~/logisim_evolution_workspace/` and keeps preferences in `~/.java/`. The script runs it with `JAVA_TOOL_OPTIONS=-Duser.home=<tmp dir>`, so both go to a temporary directory that is deleted afterwards.
- **The export is structural.** Each Logisim component becomes a component instance (`REGISTER_FLIP_FLOP`, `Adder`, `Multiplexer_bus_2`, `OR_GATE`…), so the testbench checks the drawing itself. Checked by planting a bug (incrementer constant 0x01 → 0x02): `tb_pc` failed with `increment 1: got 0x02, expected 0x01`.
- **Port names come from the pin labels**, so a circuit whose pins follow the module specification matches its testbench without an adapter (true for `pc`).
- **GHDL.** CI pins GHDL v5.1.1 (mcode). Installed locally, without root, from the official release `ghdl-mcode-5.1.1-ubuntu24.04-x86_64.tar.gz` into `~/.local/opt/ghdl-5.1.1/`. Use it with `GHDL=~/.local/opt/ghdl-5.1.1/ghdl-mcode-5.1.1-ubuntu24.04-x86_64/bin/ghdl`, or put its `bin/` on `PATH`. Ubuntu/Mint's `apt install ghdl` gives 4.1.0, older than CI.

## Known risks and open points

### Gated clock and delta-cycle skew (matters for `cpu`, not for single modules)

Logisim warns: *Component "Register" in circuit "pc" has a gated clock connection!* The clock reaches the register through an input pin (`clk`), not from a Clock component, so the generated VHDL passes it through signal assignments: `s_logisimNet3 <= clk;` in the circuit, then `s_clock <= clock` inside `REGISTER_FLIP_FLOP`. Each assignment delays the clock edge by one delta cycle, and each level of subcircuit adds one more.

Within one module every register sees the same delay, so this is harmless (`tb_pc` passes). In the full `cpu`, registers at different hierarchy depths would see the edge in different delta cycles. A register clocked later could sample a value that a register clocked earlier has already updated in the same edge: a race that exists only in simulation, not in the drawing.

To check when `cpu` is exported. Possible fixes: drive the clock from a Clock component at the top so Logisim uses its clock tree (`logisimClockTree`, clock + tick enable) instead of gated clocks; or flatten the hierarchy for the export.

### Testbenches whose ports do not map one-to-one

The generated entity has one `std_logic` / `std_logic_vector` port per pin and no generics. Some testbenches expect more and will need a small VHDL adapter (a wrapper entity with the testbench's interface around the generated one):

| Testbench | Expects | Logisim provides | Adapter |
| --- | --- | --- | --- |
| `tb_reg8` | generic `RESET_VALUE`, two instances (0x00, 0xA5) | no generics | wrapper; Logisim `reg8` needs an `rst_val` input (spec 3.3) for the 0xA5 instance |
| `tb_regfile` | port `contents : regs_t` (array) | `q_a … q_d` | wrapper packing the four bytes |
| `tb_control` | port `ctrl : ctrl_t` (record), `step : unsigned` | a 21-bit `ctrl` bus | wrapper decoding the bus into the record (spec 2.4 layout) |
| `tb_mem_io` | generic `INIT_FILE` | RAM contents from the `.circ` | open: check how Logisim exports a RAM and its initial contents |
| `tb_alu`, `tb_flags`, `tb_ir`, `tb_sp`, `tb_cpu` | plain ports | same | none expected |

### Logisim-evolution facts checked in its source (5.0.0)

- Test vectors: values without a `0x`/`0b` prefix are signed decimal unless the digit count equals the width; `<DC>` is don't care.
- Sequential test vectors: rows with the same `<set>` keep state; `<seq>` starts at 1. Only Clock components are toggled automatically, so circuits clocked by a `clk` pin drive it from the vector, two rows per cycle.
- `--load <image> <label>` loads only the RAM/ROM with that label; without a label, every RAM and ROM.
- A headless `--tty` run stops when an output pin labelled exactly `halt` is 1.
- The Adder has an HDL generator with no conditions. A "not supported for FPGA" message on it was not reproduced with 5.0.0.

## Housekeeping log

- 2026-10-21: removed `~/logisim_evolution_workspace/`, created by a manual test export before the script redirected Logisim's workspace.
