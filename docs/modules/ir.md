# IR — instruction register

> Specification: [module spec §7](../spec/sprout8-module-spec.md#7-ir--instruction-register) · Testbench: `tb_ir` · Build order: 4 of 11 · Previous: [MAR](reg8.md) · Next: [Memory and I/O](mem_io.md)

## What it does

The instruction register holds **the instruction currently being executed**. It is two bytes, because every Sprout-8 instruction is two bytes:

- **IR0**, byte 0: *what* to do (opcode) and *which registers* (rd, rs). The control unit decodes it.
- **IR1**, byte 1: the operand. An immediate value (LDI), an address (LD, ST) or a jump/call target. It goes back onto the bus when needed.

The IR is loaded during fetch and then stays still for the whole execute phase, even though memory, the bus and the PC keep changing. That stability is the whole point: the control unit and the register file read the IR fields in every execute step.

## Interface

```
             +-----------------+---> ir0[8]
    d[8] --->|                 |---> ir1[8]
   load0 --->|       ir        |---> opcode[4]   = ir0[7:4]
   load1 --->|                 |---> rd[2]       = ir0[3:2]
             +-----------------+---> rs[2]       = ir0[1:0]
               clk ^     rst ^
```

- Reset clears both bytes.
- `load0` writes byte 0 only; `load1` writes byte 1 only.
- `opcode`, `rd` and `rs` are only wires taken from `ir0`. No logic.

## Reading byte 0

```
   7   6   5   4   3   2   1   0
 +---------------+-------+-------+
 |    opcode     |  rd   |  rs   |
 +---------------+-------+-------+
```

**byte 0 = opcode × 16 + rd × 4 + rs**. In hex, the first digit is the opcode, and the second digit packs rd and rs:

| Byte 0 | Binary | opcode | rd | rs | Instruction |
| --- | --- | --- | --- | --- | --- |
| 0x71 | 0111 00 01 | 7 ADD | 00 A | 01 B | ADD A, B |
| 0xD5 | 1101 01 01 | D unary | 01 B | 01 DEC | DEC B |
| 0xE8 | 1110 10 00 | E jump | 10 NZ | 00 | JNZ |
| 0x43 | 0100 00 11 | 4 LDR | 00 A | 11 D | LDR A, \[D\] |
| 0xF2 | 1111 00 10 | F stack | 00 | 10 CALL | CALL |

The fields do not always mean "register". For the unary, system and stack groups, **rs is a function code** (INC/DEC/SHL/SHR, NOP/HLT/RET, PUSH/POP/CALL). For jumps, **rd is the condition** (always, Z, not Z, C). The IR does not care: it just delivers the bits, and the control unit interprets them.

## How it works inside

```
            +----------+
   d ------>| Reg IR0  |---- ir0 ----+---> ir0
   load0 -->| EN       |             |
            +----------+          [Splitter]
                                   |   |   |
            +----------+       opcode  rd  rs
   d ------>| Reg IR1  |---- ir1
   load1 -->| EN       |
            +----------+
```

Two independent 8-bit registers sharing the same `d` input, plus one Splitter.

## Building it in Logisim

1. Create the subcircuit `ir`. Pins: `d` (8), `load0`, `load1`, `clk`, `rst` in; `ir0` (8), `ir1` (8), `opcode` (4), `rd` (2), `rs` (2) out.
2. Two **Registers**, 8 bits each, both D ← `d`, Clear ← `rst`. Enables: `load0` and `load1`.
3. A **Splitter** on `ir0` with *fan out* 3 and bit widths 4, 2, 2. In the splitter's attributes, assign bits 7–4 to one output, 3–2 to the next, 1–0 to the last. Check that bit 0 goes to `rs`: a swapped splitter is the most common bug here.

## How the CPU uses it

| Output | Goes to | Used for |
| --- | --- | --- |
| `ir0` (whole byte) | control unit | choosing the micro-operations of the instruction |
| `rd` | register file `waddr` and `raddr_a` | the destination register, and the first ALU operand |
| `rs` | register file `raddr_b` | the second operand, or the address register of LDR/STR |
| `ir1` | bus input 3 (`bus_src` = IR1) | LDI value, LD/ST address, jump and CALL target |

IR0 is loaded in **T1** (`ir0_load`), IR1 in **T3** (`ir1_load`), both from the bus while it carries the memory output.

**Fetch must not depend on IR0.** During T0–T3 the IR still holds the *previous* instruction (or, in T2–T3, a mix of the new byte 0 and the old byte 1). The control unit must produce the same four fetch steps whatever the IR holds. `tb_control` checks this by putting junk in IR0 during fetch.

## Worked example: fetching `LDI B, #5` (B.1 at 0x02)

| Step | Bus | IR0 after | IR1 after | Fields |
| --- | --- | --- | --- | --- |
| before | | 10 | 00 | (previous: LDI A, #0) |
| T1 | M\[02\] = 14 | **14** | 00 | opcode 1, rd 01 (B), rs 00 |
| T3 | M\[03\] = 05 | 14 | **05** | |
| T4 | IR1 = 05 | 14 | 05 | B ← 05 |

## Common mistakes

| Symptom | Cause |
| --- | --- |
| ADD A, B adds into B | Splitter swapped: `rd` and `rs` exchanged |
| Opcodes look random | Splitter takes bits 3–0 as the opcode |
| LDI loads the opcode byte | `ir1_load` in T1 instead of T3, or `load0` and `load1` swapped |
| Byte 1 changes when byte 0 loads | Both registers share one enable |

## Checklist (`tb_ir`)

- [ ] Reset with both loads at 1 and `d` = 0xFF → both bytes 0x00.
- [ ] `load0` with `d` = 0x71 → `opcode` = 7, `rd` = 0, `rs` = 1; `ir1` unchanged.
- [ ] `load1` with `d` = 0x5A → `ir1` = 0x5A; `ir0` unchanged.
- [ ] Neither load → both hold.
