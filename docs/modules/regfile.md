# Register file — A, B, C, D

> Specification: [module spec §8](../spec/sprout8-module-spec.md#8-regfile--register-file-a-b-c-d) · Testbench: `tb_regfile` · Build order: 6 of 11 · Previous: [Memory and I/O](mem_io.md) · Next: [Flags](flags.md)

## What it does

The register file holds the four general-purpose registers A, B, C and D, where programs keep the values they are working on. It has:

- **one write port**: at the clock edge, R\[`waddr`\] ← `wdata` if `we` = 1;
- **two read ports**: `rdata_a` = R\[`raddr_a`\] and `rdata_b` = R\[`raddr_b`\], both instant (combinational).

### Why two read ports?

So that an ALU instruction finishes in **one step**. `ADD A, B` needs A and B at the same time, one on each ALU input. With a single read port, the CPU would first have to copy A into a temporary register, then read B, an extra step for every ALU instruction. The two ports are wired directly to the ALU, not through the bus.

## Interface

```
                +---------------------+
       we ----->|                     |---> rdata_a[8]   = R[raddr_a]
  waddr[2] ---->|                     |---> rdata_b[8]   = R[raddr_b]
  wdata[8] ---->|      regfile        |
raddr_a[2] ---->|                     |---> q_a, q_b, q_c, q_d   (debug)
raddr_b[2] ---->|                     |
                +---------------------+
                  clk ^     rst ^
```

Register codes: 00 = A, 01 = B, 10 = C, 11 = D.

## How it works inside

```
                        +-------- Reg A --------+
   wdata ---------------+-------- Reg B --------+---+---------+
                        +-------- Reg C --------+   |         |
                        +-------- Reg D --------+   |         |
                          ^ EN (one per register)   v         v
                          |                    +-------+  +-------+
   waddr --> [ 2-to-4 Decoder ] --AND we-->    | MUX 4 |  | MUX 4 |
                                               +---+---+  +---+---+
                                     raddr_a ------^           ^------ raddr_b
                                                   |           |
                                                rdata_a     rdata_b
```

- **Writing.** A 2-to-4 decoder turns `waddr` into four select lines, one per register. Each select is ANDed with `we` and drives that register's Enable. All four registers see the same `wdata`; only the enabled one takes it at the edge.
- **Reading.** Each port is a 4-input multiplexer choosing one of the four register outputs. The two multiplexers are independent, so the ports can read the same register or different ones.

### Reading a register while writing it

What does `ADD A, A` do? Port A and port B both read A, the ALU computes A + A, and the result is written to A **at the clock edge**. Before the edge, both ports still show the *old* A, so the sum is computed from the old value. After the edge, A holds the new value. No special logic is needed: edge-triggered registers give exactly this behaviour. `tb_regfile` checks that the old value is visible until the edge and the new one after it.

## Building it in Logisim

1. Create the subcircuit `regfile`. Pins as above, plus four 8-bit debug outputs `q_a`, `q_b`, `q_c`, `q_d`.
2. Four **Registers** (8 bits), D ← `wdata`, Clear ← `rst`, clock ← `clk`. Label them A, B, C, D: Logisim then shows their values when you hover over them.
3. A **Decoder** (Plexers), 2 select bits, select ← `waddr`. Four **AND** gates: decoder output *i* AND `we` → Enable of register *i*.
4. Two **Multiplexers**, 2 select bits, 8 data bits. Inputs 0–3 ← A, B, C, D. Selects ← `raddr_a` and `raddr_b`.

You may reuse your [`reg8`](reg8.md) subcircuit for the four registers instead of plain Registers.

## How the CPU uses it

| Connection | Wired to | Meaning |
| --- | --- | --- |
| `waddr` | IR `rd` | every write goes to R\[rd\] |
| `raddr_a` | IR `rd` | port A reads R\[rd\] |
| `raddr_b` | IR `rs` | port B reads R\[rs\] |
| `wdata` | bus | the value to write comes from the bus |
| `we` | `reg_we` | |
| `rdata_a` | ALU `a`, bus input 5 (RD) | first operand; data for ST, STR, PUSH |
| `rdata_b` | ALU `b` (via the 0x01 mux), bus input 6 (RS) | second operand; source of MOV; pointer for LDR, STR |

What gets written to R\[rd\], and when:

| Instruction | Step | R\[rd\] ← |
| --- | --- | --- |
| LDI | T4 | IR1 |
| MOV | T4 | R\[rs\] (port B → bus) |
| ADD … XOR, INC … SHR | T4 | ALU result |
| LD, LDR, POP | T5 | memory |

CMP, ST, STR, PUSH, jumps, CALL, RET, NOP and HLT never write a register.

## Worked example: `LDR A, [A]` (test C11)

Memory: M\[0x40\] = 0x99. Program: `LDI A, #0x40` then `LDR A, [A]` (byte 0 = 0x40: opcode 4, rd = A, rs = A).

| Step | Port B (`rs` = A) | Bus | Action | A after |
| --- | --- | --- | --- | --- |
| T4 | 40 | RS = 40 | MAR ← 40 | 40 |
| T5 | 40 | MEM = 99 | A ← 99 (`reg_we`) | **99** |

The same register is used as the address (read in T4) and as the destination (written in T5). Because the address was copied into the MAR first, writing A in T5 cannot disturb it.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| Writing B also changes A | Decoder outputs not ANDed with `we`, or enables wired to the wrong registers |
| `ADD A, B` stores into B | `waddr` wired to `rs` instead of `rd` |
| `MOV A, B` copies A into A | Bus RS input wired to port A |
| A register changes with `we` = 0 | Register enable tied to the decoder output only |

## Checklist (`tb_regfile`)

- [ ] After reset all four read 0x00 on both ports.
- [ ] Write 0x11, 0x22, 0x33, 0x44 into A–D; every combination of the two read addresses gives the right pair.
- [ ] `we` = 0 → nothing changes.
- [ ] Writing B leaves A, C, D unchanged.
- [ ] Read-during-write: with `raddr_a` = `waddr` = D, the old value shows until the tick, the new one after.
