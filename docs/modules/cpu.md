# CPU — the datapath

> Specification: [module spec §12](../spec/sprout8-module-spec.md#12-cpu--the-processor-core) · Testbench: `tb_cpu` · Build order: 10 of 11 · Previous: [Control unit](control.md) · Next: [Board](board.md)

## What it does

`cpu` is where the modules become a processor. It contains one of each: PC, SP, MAR, IR, register file, ALU, flags and control unit. It connects them around **one 8-bit bus**. Memory is outside, connected through the `mem_*` ports, so the same CPU can be tested with a model memory or used with the real `mem_io` on the board.

## The bus

The bus is the CPU's single road for data. In each clock cycle, **one** source drives it and any number of destinations can load from it.

```
 sources (bus_src)                          destinations (load signals)
   0 NONE  (0x00)  --+                  +--> MAR      (mar_load)
   1 PC            --+                  +--> IR0      (ir0_load)
   2 SP            --+    +--------+    +--> IR1      (ir1_load)
   3 IR1           --+--->| MUX 8  |----+--> PC       (pc_load)
   4 MEM (rdata)   --+    +--------+    +--> R[rd]    (reg_we)
   5 RD (port A)   --+        ^         +--> memory   (mem_write)
   6 RS (port B)   --+     bus_src
   7 ALU result    --+
```

In Logisim, build the bus as an **8-input multiplexer**, not as tri-state buffers on a shared wire. A multiplexer can never have two drivers at once (in Logisim, a red "error" wire) and never floats (a blue wire). Real CPUs often use tri-state buses; you can show that version later as a variation.

## Wiring

| Destination | Source |
| --- | --- |
| Bus mux inputs 0 … 7 | 0x00, `pc.q`, `sp.q`, `ir.ir1`, `mem_rdata`, `regfile.rdata_a`, `regfile.rdata_b`, `alu.y` |
| Bus mux select | `ctrl.bus_src` |
| `pc.d`, `mar.d`, `ir.d`, `regfile.wdata`, `mem_wdata` | the bus |
| `regfile.waddr`, `regfile.raddr_a` | `ir.rd` |
| `regfile.raddr_b` | `ir.rs` |
| `alu.a` | `regfile.rdata_a` |
| `alu.b` | `alu_b_one ? 0x01 : regfile.rdata_b` |
| `flags.z_in/c_in/n_in` | `alu.z/c/n` |
| `control.ir0`, `control.z`, `control.c` | `ir.ir0`, `flags.z`, `flags.c` |
| `mem_addr` | `mar.q` |
| `mem_we`, `mem_re` | `ctrl.mem_write`, `ctrl.mem_read` |
| every load / inc / dec input | the matching `ctrl` field |
| all `clk`, all `rst` | `clk`, `rst` |

Place a **Splitter** right next to the control unit that breaks `ctrl` into its 15 fields, and label each wire with the field name (`mar_load`, `bus_src`, …). Use **Tunnels** for the fields to avoid a web of crossing wires. The finished circuit then reads like the specification.

### The debug outputs

`tb_cpu` and the board need to see inside the CPU:

| Output | Source |
| --- | --- |
| `dbg_pc`, `dbg_sp` | PC, SP |
| `dbg_a` … `dbg_d` | register file `q_a` … `q_d` |
| `dbg_z`, `dbg_cf`, `dbg_n` | flags (`dbg_cf` is the carry flag; `dbg_c` is register C) |
| `dbg_ir0` | IR0 |
| `dbg_retire` | `ctrl.step_reset`: 1 during the last step of every instruction |
| `dbg_step` | the step counter (for a display) |
| `halted`, `illegal` | control unit |

`dbg_retire` marks the cycle at whose end an instruction completes. The state just after that clock edge is what the emulator's `--trace` prints.

## A complete instruction, signal by signal

`ADD A, B` at address 0x04 (byte 0 = 0x71), with A = 0x05, B = 0x04:

| Step | `bus_src` | Bus value | Loads at the edge | State after |
| --- | --- | --- | --- | --- |
| T0 | PC | 04 | MAR | MAR = 04 |
| T1 | MEM | 71 | IR0, PC+1 | IR0 = 71, PC = 05 |
| T2 | PC | 05 | MAR | MAR = 05 |
| T3 | MEM | 00 | IR1, PC+1 | IR1 = 00, PC = 06 |
| T4 | ALU | 09 | R\[rd\]=A, flags | A = 09, Z C N = 0 0 0, step → 0 |

During T4, the ALU's `a` = port A = R\[rd\] = A = 05 and `b` = port B = R\[rs\] = B = 04. Nothing about this was chosen by the control unit except `alu_op` = ADD: the register numbers come straight from the IR fields.

## Bring-up strategy

Do not wire everything and press run. Bring it up in stages, checking each one against the emulator:

1. **Fetch only.** Build [milestone 1](README.md#milestone-1-fetch-only) if you have not already.
2. **LDI and HLT.** A program `10 2A 01 00` (LDI A, #0x2A; HLT): A = 2A, then halted, PC = 04.
3. **ALU instructions.** Tests C2–C5 from the ISA manual's Appendix C.
4. **Memory.** LD, ST, LDR, STR: tests C11, C14, C15.
5. **Jumps.** B.1: **LEDS = 0x0F in exactly 96 cycles**.
6. **Stack.** C9 (PUSH/POP), C10 (CALL/RET), then B.2 (prints `HI!` in 172 cycles).

At each stage, compare with:

```sh
python3 sw/emulator/sprout8.py program.hex --trace
```

If the cycle count of B.1 is right, every instruction it uses has the right number of steps. If the final state is right too, the micro-operations are almost certainly right.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| Red wires on the bus | Two sources driving one wire: use the multiplexer |
| INC adds R\[A\] instead of 1 | `alu_b_one` mux missing or select inverted |
| Everything is one cycle late | A module triggered on the falling edge, or a clock passed through a gate |
| Results correct but flags never change | `flags.load` not connected to `flags_load` |
| "Oscillation apparent" error | A combinational loop, usually memory addressed from the bus instead of the MAR |

## Checklist (`tb_cpu`)

- [ ] C1: after reset, PC = 00, SP = F0, A–D = 00, flags 0, not halted.
- [ ] B.1: LEDS = 0F, 96 cycles, halted.
- [ ] B.2: terminal shows `HI!`, 172 cycles, SP = F0.
- [ ] C2–C16 from ISA Appendix C.
- [ ] After HLT: no memory reads or writes, PC and registers frozen.
