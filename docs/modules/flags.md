# Flags — Z, C, N

> Specification: [module spec §6](../spec/sprout8-module-spec.md#6-flags--condition-flags) · Testbench: `tb_flags` · Build order: 7 of 11 · Previous: [Register file](regfile.md) · Next: [SP](sp.md)

## What it does

The flags remember **three facts about the last arithmetic or logic result**, so that a later instruction can make a decision:

| Flag | Set to 1 when | Typical use |
| --- | --- | --- |
| **Z** (zero) | the result was 0x00 | "are they equal?" after CMP, "did the counter reach 0?" after DEC |
| **C** (carry) | an addition overflowed 8 bits, a subtraction borrowed, or a shift pushed out a 1 | "is A < B?" after CMP, multi-byte arithmetic |
| **N** (negative) | bit 7 of the result was 1 | sign of a result read as a signed number |

The ALU computes these facts for every result, all the time. The flags module **stores** them, but only when the control unit says so (`load`). In between, they keep their value while other instructions run. That is what lets `CMP` and `JZ` be two separate instructions.

## Interface

```
             +-----------------+
    z_in --->|                 |---> z
    c_in --->|      flags      |---> c
    n_in --->|                 |---> n
    load --->|                 |
             +-----------------+
               clk ^     rst ^
```

- Reset clears all three.
- `load` = 1: all three are written together at the clock edge.
- `load` = 0: all three hold.

There is no way to change one flag alone. ISA 3.2: an instruction that writes flags always writes all three.

## How it works inside

Three D flip-flops with one shared enable, or equivalently one 3-bit register:

```
   z_in --+                         +--> z
   c_in --+--[Splitter]--> 3-bit Register --[Splitter]--+--> c
   n_in --+                 EN <- load                  +--> n
                            Clear <- rst
```

## Building it in Logisim

1. Create the subcircuit `flags`. Pins: `z_in`, `c_in`, `n_in`, `load`, `clk`, `rst` in; `z`, `c`, `n` out.
2. Either three **D Flip-Flops** (Memory library), each with Enable ← `load` and Clear ← `rst`, or one 3-bit **Register** between two Splitters. The flip-flops are easier to read in a classroom.

## How the CPU uses it

The inputs come straight from the ALU's `z`, `c`, `n` outputs. `load` is the control signal `flags_load`.

**Instructions that write the flags** (all in T4): ADD, SUB, AND, OR, XOR, CMP, INC, DEC, SHL, SHR.

**Everything else leaves them unchanged**, notably LDI, LD, LDR, MOV, ST, STR, PUSH, POP, jumps, CALL and RET. Test C6 checks this: flags set by ADD survive LDI, MOV and ST.

**Instructions that read the flags**: only the conditional jumps. The control unit receives `z` and `c` and decides in T4:

| Jump | Byte 0 | Jumps when |
| --- | --- | --- |
| JMP | E0 | always |
| JZ / JE | E4 | Z = 1 |
| JNZ / JNE | E8 | Z = 0 |
| JC / JLO | EC | C = 1 |

N is part of the architectural state but **no v1.0 instruction reads it**. It is stored for completeness and for a future "jump if negative" or signed comparison (ISA B.4). The CPU still has to set it correctly: `tb_cpu` compares it after every instruction.

## Worked example: CMP then a jump

```
LDI A, #3
LDI B, #5
CMP A, B       ; computes 3 - 5 = 0xFE, result discarded
JC  smaller    ; jumps, because 3 < 5
```

| Instruction | ALU `y` | z_in c_in n_in | `load` | Z C N after |
| --- | --- | --- | --- | --- |
| LDI A, #3 | (not used) | – | 0 | 0 0 0 |
| LDI B, #5 | (not used) | – | 0 | 0 0 0 |
| CMP A, B | FE | 0 1 1 | **1** | **0 1 1** (test C3) |
| JC smaller | – | – | 0 | 0 1 1, and C = 1 so the jump is taken |

### The beginner's trap (B.3)

```
LD  A, [TTY_STATUS]
JZ  wait            ; WRONG: Z still describes whatever the ALU did last
```

LD does not touch the flags, so JZ would test a stale value. B.3 inserts `AND A, B` (with B = 1) between them to pass the value through the ALU.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| C6 fails: LDI or MOV changes Z | `load` wired to `reg_we` instead of `flags_load` |
| Loops never end | `load` stuck at 0: DEC does not update Z, so JNZ always sees the old value |
| Flags change between clock edges | Flip-flops replaced by plain wires from the ALU |

## Checklist (`tb_flags`)

- [ ] Reset with all inputs and `load` at 1 → Z C N = 0 0 0.
- [ ] `load` = 1 with each of the 8 input patterns → the outputs match after one tick.
- [ ] `load` = 0 and inputs inverted → outputs unchanged after ticks.
- [ ] Outputs change only at the tick, never in between.
