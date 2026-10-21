# PC — program counter

> Specification: [module spec §4](../spec/sprout8-module-spec.md#4-pc--program-counter) · Testbench: `tb_pc` · Build order: 2 of 11 · Previous: [ALU](alu.md) · Next: [MAR](reg8.md)

## What it does

The program counter is an 8-bit register that holds **the address of the next instruction byte to fetch**. Every instruction is 2 bytes, so in a straight-line program the PC moves forward by 2 per instruction, one byte at a time during fetch.

It changes in only two ways:

- **increment**: PC ← PC + 1, during fetch;
- **load**: PC ← a value from the bus, for jumps, CALL and RET.

## Interface

```
            +-----------------+
   d[8] --->|                 |
   load --->|       pc        |---> q[8]
    inc --->|                 |
            +-----------------+
              clk ^     rst ^
```

| `rst` | `load` | `inc` | `q` after the clock edge |
| --- | --- | --- | --- |
| 1 | – | – | 0x00 |
| 0 | 1 | – | `d` (**load beats inc**) |
| 0 | 0 | 1 | `q + 1`, with 0xFF wrapping to 0x00 |
| 0 | 0 | 0 | `q` (hold) |

## How it works inside

```
                 +-------+
   q ----------->| +1    |---+        (8-bit Adder, b = 0x01,
                 +-------+   |         carry out ignored: 0xFF + 1 = 0x00)
                             v
                          +-----+
   d ------------------->1|     |
                          | MUX |----> D  +----------+
                     +-->0|     |         | Register |---> q
                     |    +--+--+         |  8 bits  |
                     |       | sel        |          |
            (q+1) ---+     load           | EN       |
                                          +----------+
              load OR inc ---------------->  EN
              rst  ----------------------->  Clear
```

Three parts:

1. An **adder** keeps computing `q + 1` all the time. It does not matter that this value is usually not used.
2. A **multiplexer** chooses what the register will take: the bus value `d` when `load` = 1, otherwise `q + 1`. Because `load` drives the select, load automatically beats inc.
3. The register's **enable** is `load OR inc`. When both are 0 the register is not enabled and keeps its value. That is why the multiplexer needs no third "hold" input.

**Wrap-around** is free. The adder is 8 bits wide and its carry out is not connected, so 0xFF + 1 gives 0x00. The ISA requires exactly this (ISA 4.2: all address arithmetic is mod 256).

## Building it in Logisim

1. Create the subcircuit `pc`. Pins: `d` (8), `load`, `inc`, `clk`, `rst` in; `q` (8) out.
2. Memory library: a **Register**, *Data Bits* = 8, trigger on the rising edge. Connect `rst` to its **Clear** input. That is allowed here because the PC resets to 0x00.
3. Arithmetic library: an **Adder**, 8 bits. Input a ← `q`, input b ← a Constant 0x01 (8 bits). Leave carry in and carry out unconnected.
4. Plexers library: a **Multiplexer**, 1 select bit, 8 data bits. Input 0 ← adder output, input 1 ← `d`, select ← `load`. Output → register D.
5. An **OR** gate: `load`, `inc` → register Enable.

> **Do not use Logisim's Counter component** for the PC, even though it looks like a ready-made program counter. In the Logisim versions we know of, a Counter with both *load* and *count* active counts **down**, which breaks "load beats inc". Check the component's help page in your version if you want to try it. The register + adder + mux version also shows what a counter is made of.

## How the CPU uses it

The control unit drives three things: `pc_inc`, `pc_load`, and `bus_src = PC` (put the PC on the bus).

| Step | PC action | Why |
| --- | --- | --- |
| T0 | PC → bus → MAR | address of byte 0 |
| T1 | **PC ← PC + 1** | byte 0 is read into IR0 at the same edge |
| T2 | PC → bus → MAR | address of byte 1 |
| T3 | **PC ← PC + 1** | byte 1 is read into IR1 at the same edge |
| T4, Jcc taken | **PC ← IR1** | the jump target |
| T5, RET | **PC ← M\[SP\]** | the return address, from the stack |
| T6, CALL | PC → bus → M\[SP\] | push the return address |
| T7, CALL | **PC ← IR1** | the subroutine address |

### Why the PC can increment in the same step as the read

In T1, memory reads the address held in the **MAR**, which was copied from the PC in T0. The PC can therefore change at the end of T1 without disturbing the read. This is the reason the design has a MAR at all: memory is never addressed by the PC directly (see the [MAR guide](reg8.md)).

### Why "PC already points to the next instruction"

After T3, the PC is the instruction's own address + 2. The ISA manual (§6) writes all instruction pseudocode with this in mind, and several behaviours come for free:

- **CALL** pushes the PC as it is in T6. That value is already the address of the instruction after the CALL, the correct return address. No adder needed.
- **A jump that is not taken** does nothing to the PC. It already points at the next instruction.
- **HLT and illegal instructions** leave PC = address + 2, as ISA 5.4 and 6.5 require. Conformance test C13 checks this: PC = 0x04 after the illegal instruction at 0x02.

### Load and inc together never happen in practice

`pc_inc` is only active in T1 and T3; `pc_load` only in T4–T7. The "load beats inc" rule makes the module fully defined, and `tb_pc` tests it, but a correct control unit never asserts both.

### When halted

The control unit forces the whole control word to zero while halted, so `inc` = `load` = 0 and the PC stays frozen.

## Worked example: the start of B.1

```
00: 10 00     LDI  A, #0
02: 14 05     LDI  B, #5
04: 71 00     loop: ADD A, B
06: D5 00     DEC  B
08: E8 04     JNZ  loop
0A: 30 F0     ST   A, [LEDS]
0C: 01 00     HLT
```

| Cycle | Step | MAR | PC after the edge | Note |
| --- | --- | --- | --- | --- |
| reset | – | 00 | 00 | |
| 1 | T0 | 00 | 00 | MAR ← PC |
| 2 | T1 | 00 | **01** | IR0 ← 0x10 |
| 3 | T2 | 01 | 01 | MAR ← PC |
| 4 | T3 | 01 | **02** | IR1 ← 0x00 |
| 5 | T4 | 01 | 02 | A ← 0. The next instruction is at 02 |
| 6–10 | T0–T4 | 02, 03 | 03, **04** | LDI B, #5 |
| … | | | | |
| JNZ T3 | | 09 | **0A** | JNZ fully fetched |
| JNZ T4 | | 09 | **04** if Z = 0, else stays **0A** | the loop |

### Wrap-around (test C7)

`JMP 0xFE` at address 0x00 loads PC = 0xFE. The CPU fetches 0xFE and 0xFF (both 0x00, a NOP). The second increment takes 0xFF to **0x00**, and execution continues from address 0x00 again.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| PC advances by 1 per clock forever | Enable tied to 1 instead of `load OR inc` |
| Jumps go to `target + 1` | Mux inputs swapped (`load` selects `q + 1`) |
| Every instruction is fetched twice | The control unit increments in T0/T2 instead of T1/T3 |
| PC jumps when it should increment | Using the Counter component with load and count both active |

## Checklist (`tb_pc`)

Poke the inputs and tick the clock (Ctrl-T) by hand:

- [ ] `rst` = 1 with `load` = 1, `inc` = 1, `d` = 0xAA → `q` = 0x00 (reset beats everything).
- [ ] All inputs 0, two ticks → `q` unchanged.
- [ ] `inc` = 1 for many ticks → 01, 02, … and 0xFF → 0x00.
- [ ] `load` = 1, `d` = any value → `q` = `d` after one tick.
- [ ] `load` = 1, `inc` = 1, `d` = 0x40 → 0x40. Then `load` = 0 → 0x41.
- [ ] Load 0xFF, then increment → 0x00.
