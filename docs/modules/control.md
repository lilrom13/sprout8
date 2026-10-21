# Control unit

> Specification: [module spec §11](../spec/sprout8-module-spec.md#11-control--control-unit) · Testbench: `tb_control` · Build order: 9 of 11 · Previous: [SP](sp.md) · Next: [CPU](cpu.md)

## What it does

Every other module is a **datapath** part: it stores, computes or moves data, but only when told to. The control unit is what tells them. Once per clock cycle it looks at the current instruction and the current step, and produces a **control word**: 21 bits saying which register drives the bus, which registers load, whether memory reads or writes, and what the ALU computes.

Think of it as the conductor: the datapath parts are the musicians, the control word is the score for one beat, and the step counter counts the beats.

## Interface

```
             +--------------------+
   ir0[8] -->|                    |---> ctrl[21]
        z -->|      control       |---> step[3]
        c -->|                    |---> halted
             |                    |---> illegal
             +--------------------+
               clk ^     rst ^
```

## The three parts

```
                       +-------------------+
   ir0, z, c --------->|                   |
                       |     decoder       |--- control word ---[AND NOT halted]---> ctrl
            +--------->| (ROM or gates)    |
            |          +-------------------+
            |                 | step_reset    | halt   | illegal
            |                 v               v        v
      +-----+------+     next step       +--------+ +---------+
      |   step     |<--- logic           | halted | | illegal |
      |  counter   |     (0 or step+1)   |  flop  | |  flop   |
      +------------+                     +--------+ +---------+
           EN <- NOT halted
```

### 1. The step counter

A 3-bit register counting T0, T1, T2, … At each clock edge it either:

- goes to **0** if the current control word has `step_reset` (the instruction is finished), or
- goes to **step + 1** otherwise.

So short instructions take 5 steps (T0–T4) and CALL, the longest, takes 8 (T0–T7). 3 bits are enough.

### 2. The decoder

A purely combinational function:

```
(ir0, step, z, c)  -->  control word
```

It contains the whole instruction set. There are two ways to build it, described below.

### 3. The halt logic

Two flip-flops, `halted` and `illegal`, set by the `halt` and `illegal` bits of the control word and cleared only by reset. While `halted` = 1:

- the step counter stops (its enable is NOT `halted`);
- every bit of `ctrl` is forced to 0 (AND with NOT `halted`), so nothing in the datapath moves.

## The instruction cycle

Every instruction starts with the same four **fetch** steps. They do not depend on IR0, because the IR still holds the previous instruction during them.

| Step | Bus | Signals | Meaning |
| --- | --- | --- | --- |
| T0 | PC | `mar_load` | MAR ← PC |
| T1 | MEM | `ir0_load mem_read pc_inc` | IR0 ← M\[MAR\]; PC ← PC + 1 |
| T2 | PC | `mar_load` | MAR ← PC |
| T3 | MEM | `ir1_load mem_read pc_inc` | IR1 ← M\[MAR\]; PC ← PC + 1 |

Then the **execute** steps, from T4. The full table is in the [specification §11.3](../spec/sprout8-module-spec.md#113-micro-operation-table). Read it with one rule in mind: **one bus transfer per step**. Each step moves one value from one source to one or more destinations.

### Example: LD B, \[0x40\] (6 cycles)

| Step | Bus | Signals | Meaning |
| --- | --- | --- | --- |
| T4 | IR1 | `mar_load` | MAR ← 0x40 |
| T5 | MEM | `reg_we mem_read step_reset` | B ← M\[0x40\]; done |

### Example: ADD A, B (5 cycles)

| Step | Bus | Signals | Meaning |
| --- | --- | --- | --- |
| T4 | ALU | `reg_we flags_load step_reset`, `alu_op` = ADD | A ← A + B; flags; done |

The ALU's operands come straight from the register file's two read ports, not over the bus, so the whole operation fits in one step.

### Example: CALL 0x12 at address 0x0A (8 cycles)

| Step | Bus | Signals | Meaning |
| --- | --- | --- | --- |
| T4 | – | `sp_dec` | SP ← SP − 1 |
| T5 | SP | `mar_load` | MAR ← SP |
| T6 | PC | `mem_write` | M\[SP\] ← 0x0C (return address) |
| T7 | IR1 | `pc_load step_reset` | PC ← 0x12; done |

### Example: JNZ, taken or not (5 cycles)

| Z | T4 bus | T4 signals |
| --- | --- | --- |
| 0 (taken) | IR1 | `pc_load step_reset` |
| 1 (not taken) | – | `step_reset` |

A jump that is not taken still takes 5 cycles: it does nothing in T4 and ends.

### HLT and illegal instructions

HLT: T4 is `step_reset halt`. The step returns to 0 and `halted` becomes 1 at the same edge, so the CPU freezes before fetching anything else, with PC pointing after the HLT.

The reserved encodings (byte 0 = 0x03, 0x07, 0x0B, 0x0F, 0xF3, 0xF7, 0xFB, 0xFF): T4 is `step_reset halt illegal`. The board shows a separate ILLEGAL light. Memory full of 0xFF (erased) therefore halts immediately instead of running garbage.

## Option A: a microcode ROM (build this first)

Put the whole decoder in a ROM. The ROM address is made of the decoder's inputs, and each word is a control word:

```
 address (13 bits):   ir0[7:0]   z   c   step[2:0]
                      12      5  4   3   2       0
 data (21 bits):      the control word, spec section 2.4
```

- 2^13 = 8,192 words: one for every (instruction byte, flags, step) combination.
- Including Z and C in the address means the ROM decides jumps itself: the "taken" and "not taken" words are simply different entries.
- The ROM's contents are generated by a script (`tools/gen_microcode.py`, not written yet) from the micro-operation table. Nobody types 8,192 words.

In Logisim: a **ROM** component with 13 address bits and 21 data bits, its address built from a Splitter (fan in) of `ir0`, `z`, `c`, `step`, and its output split into named fields. Load the image with right-click → Load Image.

**Why first?** It is quick to build, all the logic lives in one well-tested table, and it gets the CPU running. You can then study and replace it.

## Option B: hardwired logic (build this second)

The same function as gates. This is how most real simple CPUs do it, and it shows what a decoder really is.

1. **Decode the inputs into one-hot lines.** A 3-to-8 decoder on `step` gives T0…T7. A 4-to-16 decoder on the opcode gives OP0…OPF. A 2-to-4 decoder on `rs` gives F0…F3.
2. **Name the instructions** with AND gates, e.g. `PUSH = OPF · F0`, `RET = OP0 · F2`.
3. **Write each control signal as a sum of (step · instruction) terms.** Read the table column by column. For example, `mem_write` is active in T5 of ST and STR and in T6 of PUSH and CALL:

   ```
   mem_write = T5·(ST + STR) + T6·(PUSH + CALL)
   ```

All the equations are in the [specification §11.6](../spec/sprout8-module-spec.md#116-implementation-option-b-hardwired-decoder). They were checked against `tb_control`'s table for all 256 byte-0 values and all four Z/C combinations.

The bus source is encoded in two stages. First one "drives the bus" line per source (`drv_PC`, `drv_SP`, …, of which at most one is 1 in any step), then three OR gates turn them into the 3-bit `bus_src` code.

## Building it in Logisim

1. Create the subcircuit `control`. Pins as in the interface.
2. Step counter: a 3-bit **Register**, Clear ← `rst`, Enable ← NOT `halted`. D ← a 2:1 mux of `step + 1` (3-bit Adder) and 0, selected by `step_reset`.
3. Two **D Flip-Flops** for `halted` and `illegal`: D ← 1, Enable ← the `halt` (resp. `illegal`) bit, Clear ← `rst`. Once set, they stay set until reset.
4. The decoder (option A or B).
5. One 21-bit **AND** (or AND each field) with NOT `halted` before the `ctrl` output.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| Every instruction is fetched wrong | Fetch steps depend on IR0, e.g. ROM blocks with different T0–T3 words |
| CPU keeps running after HLT | `ctrl` not gated, or counter enable not tied to NOT `halted` |
| HLT halts one instruction late | `halted` set from the step after `step_reset` instead of together with it |
| Jumps taken when they should not be | Z and C swapped in the ROM address, or the condition uses `rs` instead of `rd` |
| B.1 takes more than 96 cycles | An instruction missing `step_reset` in its last step |

## Checklist (`tb_control`)

Connect test pins to `ir0`, `z`, `c` and watch `ctrl` while ticking:

- [ ] After reset, `step` = 0 and the control word is the T0 word (`bus` = PC, `mar_load`).
- [ ] With `ir0` = 0x71 (ADD A, B): 5 steps, T4 = ALU, `reg_we flags_load step_reset`, `alu_op` = 0.
- [ ] With `ir0` = 0xF2 (CALL): 8 steps, matching the CALL table above.
- [ ] With `ir0` = 0xE8 (JNZ): `pc_load` in T4 only when Z = 0.
- [ ] With `ir0` = 0x01 (HLT): `halted` = 1 after T4; `ctrl` = 0 and `step` frozen afterwards; reset clears it.
- [ ] With `ir0` = 0xFF: `halted` = 1 and `illegal` = 1.
