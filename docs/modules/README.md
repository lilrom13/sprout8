# Sprout-8 module guides

One page per hardware module of the reference implementation. Each guide explains what the module is for, how it works inside, how to build it in Logisim-evolution, how the CPU uses it instruction by instruction, a worked example, the usual mistakes, and the checks to pass before moving on.

The short normative definition of every module (ports, truth tables, encodings) is in the [module specification](../spec/sprout8-module-spec.md). The guides add explanation; where they and the specification disagree, the specification wins.

## Suggested build order

The order puts something you can see working at every stage. The ALU comes first because it is purely combinational and teaches most of the Logisim components used later. Then the parts needed to fetch instructions, because fetch is where clocking and memory-timing mistakes show up.

| # | Guide | What you can do once it is built |
| --- | --- | --- |
| 1 | [ALU](alu.md) | Run the generated ALU test vectors |
| 2 | [PC — program counter](pc.md) | Count through addresses |
| 3 | [MAR — `reg8`](reg8.md) | Hold an address for memory |
| 4 | [IR — instruction register](ir.md) | Hold and decode an instruction |
| 5 | [Memory and I/O — `mem_io`](mem_io.md) | Store a program. **Milestone 1** below |
| 6 | [Register file](regfile.md) | Hold A, B, C, D |
| 7 | [Flags](flags.md) | Remember Z, C, N |
| 8 | [SP — stack pointer](sp.md) | Push and pop addresses |
| 9 | [Control unit](control.md) | Sequence every instruction |
| 10 | [CPU — the datapath](cpu.md) | Run programs. **Milestone 2** below |
| 11 | [Board](board.md) | Use LEDs, switches, terminal and keyboard |

## Milestone 1: fetch only

Before building the control unit, check that instructions can be fetched. Make a temporary circuit `fetch_test` with:

- a clock and a reset button;
- `pc`, `reg8` (as the MAR), `ir`, and `mem_io` (the RAM is enough; the I/O ports can wait);
- an 8-input bus multiplexer, as in the [CPU guide](cpu.md);
- a 2-bit counter (a 2-bit Register plus an Adder) that steps T0, T1, T2, T3, T0, …, and a few gates that produce the four fetch control words:

| Step | bus | Signals |
| --- | --- | --- |
| T0 | PC | `mar_load` |
| T1 | MEM | `ir0_load`, `mem_read`, `pc_inc` |
| T2 | PC | `mar_load` |
| T3 | MEM | `ir1_load`, `mem_read`, `pc_inc` |

Load `build/logisim/b1_sum_leds.img` (from `make logisim`) into the RAM, reset, and step the clock. IR0/IR1 should show 10/00, then 14/05, then 71/00, D5/00, E8/04, 30/F0, 01/00, and PC should advance by 2 per instruction. If they do, your clocking, RAM timing and bus are right.

## Milestone 2: the first program

With the whole CPU built, load B.1 and run it. Pass criterion: **LEDS = 0x0F after exactly 96 clock cycles**, and the CPU halts. Compare the state after each instruction with the emulator:

```sh
python3 sw/emulator/sprout8.py sw/programs/b1_sum_leds.hex --trace
```

```
00: PC=02 SP=F0 A=00 B=00 C=00 D=00 Z=0 C=0 N=0 LEDS=00
02: PC=04 SP=F0 A=00 B=05 C=00 D=00 Z=0 C=0 N=0 LEDS=00
04: PC=06 SP=F0 A=05 B=05 C=00 D=00 Z=0 C=0 N=0 LEDS=00
...
```

Each line is the state **after** the instruction at the address on the left. In Logisim, that is the state just after the clock edge that ends the instruction's last step (`dbg_retire` = 1 before that edge).

## Tools

| Command | Produces |
| --- | --- |
| `make logisim` | Program images and test vectors in `build/logisim/` |
| `python3 tools/hex2logisim.py <prog.hex>` | One RAM image (`v3.0 hex words addressed`) |
| `python3 tools/gen_logisim_vectors.py [module] [--exhaustive]` | Test vectors: `alu` (combinational), `pc` (sequential) |
| `make logisim-tb TB=tb_<module>` | Exports the Logisim circuit to VHDL and runs its testbench with GHDL (see [`hw/logisim/NOTES.md`](../../hw/logisim/NOTES.md)) |
| `python3 sw/emulator/sprout8.py <prog.hex> --trace` | The expected state after every instruction |
