# Board — the Logisim top level (`sprout8_board`)

> Specification: [module spec §13](../spec/sprout8-module-spec.md#13-sprout8_board--logisim-top-level) · Testbench: the Appendix B programs · Build order: 11 of 11 · Previous: [CPU](cpu.md)

## What it does

The board is the circuit you actually run: the CPU, its memory, a clock, a reset button, and the devices a program can talk to. It plays the role of a physical development board. Everything inside `cpu` and `mem_io` is the computer; everything on the board around them is the outside world.

The VHDL design has no board: `tb_cpu` replaces it with a keyboard model and a terminal capture.

## Layout

```
 +--------------------------------------------------------------------+
 |  [Clock]  [RESET]       PC [hh]  SP [hh]  IR0 [hh]  step [h]       |
 |                         A  [hh]  B  [hh]  C   [hh]  D    [hh]      |
 |                         Z C N  o o o      HALTED o   ILLEGAL o     |
 |                                                                    |
 |   +-------+   mem_addr / wdata / we / re    +---------+            |
 |   |  cpu  |-------------------------------->| mem_io  |            |
 |   |       |<--------------- rdata ----------|  (ram)  |            |
 |   +-------+                                 +---------+            |
 |                                              |  |  |  |            |
 |   LEDS  o o o o o o o o  <-------------------+  |  |  |            |
 |   SWITCHES [########]  ------------------------>+  |  |            |
 |   +-------------------+                            |  |            |
 |   |  TTY  (terminal)  |<---------------------------+  |            |
 |   +-------------------+                               |            |
 |   [ Keyboard ] -------------------------------------->+            |
 +--------------------------------------------------------------------+
```

## Components and connections

| Element | Logisim component (library) | Connection |
| --- | --- | --- |
| Clock | Clock (Wiring) | `clk` of `cpu`, `mem_io`, TTY and Keyboard |
| Reset | Button (Input/Output) | `rst` of `cpu` and `mem_io` |
| LEDs | 8 × LED (Input/Output), bit 0 on the right | `mem_io.leds` through a Splitter |
| Switches | DIP Switch, 8 (Input/Output) | `mem_io.switches` |
| Terminal | TTY (Input/Output) | Data ← `tty_out_data[6:0]`, Write Enable ← `tty_out_valid`, clock ← `clk` |
| Keyboard | Keyboard (Input/Output) | Data (7 bits) → zero-extend → `tty_in_data`; Available → `tty_in_valid`; Read Enable ← `tty_in_ack`; clock ← `clk` |
| Displays | Hex Digit Display (Input/Output), two per byte | `dbg_pc`, `dbg_sp`, `dbg_a`…`dbg_d`, `dbg_ir0`, `dbg_step` |
| Status | 2 × LED | HALTED ← `halted`, ILLEGAL ← `illegal` |

### Notes

- **TTY and Keyboard are 7-bit (ASCII).** Take bits 6–0 of `tty_out_data` with a Splitter. For the keyboard, add a 0 bit on top with a Splitter (fan in) or a Bit Extender set to zero extension.
- **The handshakes are clocked.** The TTY prints a character at the clock edge where Write Enable is 1; the Keyboard drops its first character at the clock edge where Read Enable is 1. Both use the same clock as the CPU, which is why `tty_out_valid` and `tty_in_ack` are one-cycle pulses.
- **Two separate status lights.** ISA 5.4 recommends that an illegal instruction look different from HLT.
- **Hex displays.** Each Hex Digit Display shows 4 bits; split each byte into two nibbles.

## Running a program

1. `make logisim` to build the RAM images in `build/logisim/`.
2. Open the board. Right-click the RAM inside `mem_io` (labelled `ram`) → **Load Image…** → `b1_sum_leds.img`.
3. Press **RESET** with the Poke tool while ticking the clock once (Ctrl-T), so the reset is seen at a clock edge.
4. **Simulate → Ticks Enabled** (Ctrl-K) to run, or Ctrl-T to step one clock edge at a time. Choose a tick frequency of a few Hz to watch the PC move, or the maximum to finish quickly.

Expected results:

| Program | Result |
| --- | --- |
| B.1 `b1_sum_leds` | LEDs show 0000 1111 (0x0F), then HALTED lights. 96 cycles |
| B.2 `b2_print_string` | Terminal prints `HI!`, then HALTED. 172 cycles, SP back to F0 |
| B.3 `b3_echo` | Click the Keyboard, type: every key appears on the terminal. Never halts |

### Comparing with the emulator

```sh
python3 sw/emulator/sprout8.py sw/programs/b2_print_string.hex --trace
```

Each line shows the state after one instruction. Step the board until `step` returns to 0 (one instruction) and compare the displays with the line. The first line that differs names the faulty instruction. Then step that instruction one clock at a time and compare with the micro-operation table in the [control unit guide](control.md).

## Headless runs

Logisim-evolution can run without its window, which makes automatic checks possible later:

```sh
java -jar logisim-evolution.jar --tty table --load build/logisim/b1_sum_leds.img ram hw/logisim/sprout8.circ
```

`--load <image> ram` loads only the RAM labelled `ram`. Without the label, Logisim would load the image into every RAM and ROM, including the microcode ROM. For a headless run to stop, the top circuit needs an output pin labelled `halt` (connect it to `halted`). Check the available `--tty` formats with `--help` in your version.

## Checklist

- [ ] B.1, B.2 and B.3 behave as in the table above.
- [ ] Pressing RESET in the middle of a program restarts it from 0x00, with the program still in RAM.
- [ ] Loading a RAM full of 0xFF → ILLEGAL lights after the first instruction.
- [ ] Flipping switches and running `LD A, [0xF1]` then `ST A, [0xF0]` copies the switches to the LEDs.
