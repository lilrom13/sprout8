# SP — stack pointer

> Specification: [module spec §5](../spec/sprout8-module-spec.md#5-sp--stack-pointer) · Testbench: `tb_sp` · Build order: 8 of 11 · Previous: [Flags](flags.md) · Next: [Control unit](control.md)

## What it does

The stack pointer holds **the address of the most recently pushed byte**. The stack is a region of RAM just below the I/O ports, and it grows **downward**:

```
 0xF0 +------------------+  <- SP after reset (nothing pushed yet)
 0xEF |  first push      |  <- SP after one PUSH
 0xEE |  second push     |  <- SP after two PUSHes
      |        v         |
```

The stack is used by PUSH and POP (to save registers) and by CALL and RET (to remember where to return).

SP is a counter like the [PC](pc.md), with two differences:

- it can count **down** as well as up;
- it resets to **0xF0**, not 0x00.

It has no load input: no instruction sets SP to an arbitrary value in v1.0.

## Interface

```
            +-----------------+
    inc --->|                 |
    dec --->|       sp        |---> q[8]
            +-----------------+
              clk ^     rst ^
```

| `rst` | `inc` | `dec` | `q` after the edge |
| --- | --- | --- | --- |
| 1 | – | – | **0xF0** |
| 0 | 1 | 0 | `q` + 1 (0xFF wraps to 0x00) |
| 0 | 0 | 1 | `q` − 1 (0x00 wraps to 0xFF) |
| 0 | 1 | 1 | `q` (they cancel) |
| 0 | 0 | 0 | `q` |

## How it works inside

```
                       0x01 --1|     |
                               | MUX |--+
                       0xFF --0|     |  |
                               +--^--+  |
                                  inc   v
                 +---------------------[ Adder ]<-- q
                 |                        |
                 |                     sum|
                 |                    +---v---+
        0xF0 ----+------------------>1|  MUX  |---> D  +----------+
                                      |       |        | Register |---> q
                                      +---^---+        |  8 bits  |
                                          rst          |          |
            rst OR (inc XOR dec) ----------------------> EN       |
                                                       +----------+
```

### Counting down with an adder

Subtracting 1 is the same as **adding 0xFF** when you only keep 8 bits: 0x05 + 0xFF = 0x104, keep the low 8 bits → 0x04. So one adder handles both directions. Its second input is 0x01 when counting up, 0xFF when counting down.

### Why the reset needs a multiplexer

Logisim's Register can only reset to 0 through its Clear pin. SP must reset to 0xF0. So instead of Clear, put a multiplexer in front of D that chooses the constant 0xF0 when `rst` = 1, and include `rst` in the enable. The reset then happens at the clock edge, like all other changes (a synchronous reset).

### The enable

`inc XOR dec` is 1 when exactly one of them is active. If both are active, the register does not change: this is the "they cancel" row. OR with `rst` so that reset always loads 0xF0.

## Building it in Logisim

1. Create the subcircuit `sp`. Pins: `inc`, `dec`, `clk`, `rst` in; `q` (8) out.
2. A **Register**, 8 bits. **Do not connect Clear.**
3. An **Adder**, 8 bits: a ← `q`, b ← a 2:1 **Multiplexer** of Constants 0xFF (input 0) and 0x01 (input 1), selected by `inc`.
4. A 2:1 **Multiplexer** for D: input 0 ← adder sum, input 1 ← Constant 0xF0, select ← `rst`.
5. Enable ← `rst OR (inc XOR dec)`.

## How the CPU uses it

SP is only ever changed by `sp_inc` and `sp_dec`, and read onto the bus (`bus_src` = SP), from where it goes into the [MAR](reg8.md).

**Pushing: decrement first, then write.** SP points at the last pushed byte, so the next free byte is SP − 1.

| Step | PUSH rd | CALL target |
| --- | --- | --- |
| T4 | SP ← SP − 1 | SP ← SP − 1 |
| T5 | MAR ← SP | MAR ← SP |
| T6 | M\[MAR\] ← R\[rd\] | M\[MAR\] ← PC (return address) |
| T7 | | PC ← IR1 |

**Popping: read first, then increment.**

| Step | POP rd | RET |
| --- | --- | --- |
| T4 | MAR ← SP | MAR ← SP |
| T5 | R\[rd\] ← M\[MAR\] | PC ← M\[MAR\] |
| T6 | SP ← SP + 1 | SP ← SP + 1 |

The SP update gets a step of its own. A faster design could merge it with a neighbouring step, because SP only changes at the clock edge, but the reference design keeps one action per step so the micro-operations are easy to follow.

## Worked example: test C9

```
LDI A, #1
LDI B, #2
PUSH A
PUSH B
POP  A
POP  B
```

| After | SP | M\[EF\] | M\[EE\] | A | B |
| --- | --- | --- | --- | --- | --- |
| reset | F0 | – | – | 00 | 00 |
| LDI, LDI | F0 | – | – | 01 | 02 |
| PUSH A | **EF** | 01 | – | 01 | 02 |
| PUSH B | **EE** | 01 | 02 | 01 | 02 |
| POP A | **EF** | 01 | 02 | **02** | 02 |
| POP B | **F0** | 01 | 02 | 02 | **01** |

A and B are swapped, and SP is back at 0xF0: last in, first out. Popping does not erase the bytes, it only moves SP.

### CALL and RET (B.2)

`CALL putc` at address 0x0A, with `putc` at 0x12. After fetch, PC = 0x0C.

- CALL: SP 0xF0 → **0xEF**; M\[EF\] ← **0x0C**; PC ← **0x12**.
- RET (at 0x14): PC ← M\[EF\] = **0x0C**; SP → **0xF0**.

### Wrap-around (test C8)

Sixteen POPs from 0xF0 bring SP to 0x00. A PUSH then decrements to **0xFF** and writes to 0xFF, a reserved I/O port, so the write is ignored. No error: the hardware does not protect the stack. Keeping the stack in its region is the software's job.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| SP = 0x00 after reset | Reset through the Clear pin |
| First push writes 0xF0 (the LEDs) | Write before the decrement, or decrement in the wrong step |
| POP returns the wrong value | Increment before the read |
| SP changes by 2 when both are active | Enable is `inc OR dec` instead of XOR |

## Checklist (`tb_sp`)

- [ ] Reset (even with `dec` = 1) → 0xF0.
- [ ] One `dec` → 0xEF.
- [ ] Many `dec` → wraps 0x00 → 0xFF.
- [ ] From reset, 16 `inc` → 0x00; one `dec` → 0xFF.
- [ ] `inc` and `dec` together → unchanged.
