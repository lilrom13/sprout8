# MAR — memory address register (`reg8`)

> Specification: [module spec §3](../spec/sprout8-module-spec.md#3-reg8--generic-8-bit-register) · Testbench: `tb_reg8` · Build order: 3 of 11 · Previous: [PC](pc.md) · Next: [IR](ir.md)

## What it does

The MAR holds **the address that memory is currently reading or writing**. Its output is the only thing connected to the memory's address input.

The module itself is the simplest one in the CPU, a plain 8-bit register with a load enable, called `reg8` because it is generic. The interesting part is *why* the CPU needs it.

## Why the CPU needs a MAR

The CPU has **one shared bus**. In any clock cycle, exactly one source drives it. A memory access needs two things at the same time, an address and the data, so they cannot both travel on the bus in the same cycle.

The solution: send the address over the bus **one cycle earlier** and park it in the MAR. In the next cycle the bus is free to carry the data.

```
  cycle 1:   [address source] --bus--> MAR            (mar_load)
  cycle 2:   MAR ----------------------> memory address
             memory data <---bus----> register        (mem_read or mem_write)
```

Two other benefits:

- **The PC can move during a read.** In T1, memory reads at the MAR (copied from the PC in T0) while the PC increments at the same edge. See the [PC guide](pc.md).
- **No combinational loop.** If the memory address came straight from the bus, then in a read cycle the bus would carry the memory output, which depends on the address, which comes from the bus. Logisim would show oscillation or an error. The MAR breaks that loop with a register.

## Interface

```
            +-----------------+
   d[8] --->|                 |
   load --->|      reg8       |---> q[8]
            +-----------------+
              clk ^     rst ^
```

| `rst` | `load` | `q` after the edge |
| --- | --- | --- |
| 1 | – | `RESET_VALUE` (0x00 for the MAR) |
| 0 | 1 | `d` |
| 0 | 0 | `q` (hold) |

## How it works inside

It is one Register component:

```
   d ------> D  +----------+
                | Register |---> q
   load ---> EN |  8 bits  |
   rst  ---> Clear         |
                +----------+
```

The VHDL version has a `RESET_VALUE` generic. Logisim subcircuits have no generics. Build `reg8` with a reset value of 0x00 using the Clear pin, which is all the MAR needs. If you want to reuse `reg8` with another reset value, add an 8-bit input `rst_val` and a reset multiplexer, as in the [SP guide](sp.md).

## Building it in Logisim

1. Create the subcircuit `reg8`. Pins: `d` (8), `load`, `clk`, `rst` in; `q` (8) out.
2. One **Register**, 8 data bits: D ← `d`, Enable ← `load`, Clear ← `rst`, clock ← `clk`, Q → `q`.

In the `cpu` circuit, place it once and label the instance `MAR`.

## How the CPU uses it

The MAR is loaded (`mar_load`) from the bus, from four different sources depending on where the address comes from:

| Instruction | Step | MAR ← | Then, next step |
| --- | --- | --- | --- |
| every instruction | T0 | PC | T1: IR0 ← M\[MAR\] |
| every instruction | T2 | PC | T3: IR1 ← M\[MAR\] |
| LD, ST | T4 | IR1 (the absolute address) | T5: read or write |
| LDR, STR | T4 | R\[rs\] (the pointer register) | T5: read or write |
| POP, RET | T4 | SP | T5: read |
| PUSH, CALL | T5 | SP (after the decrement in T4) | T6: write |

Every memory access in the CPU follows the same pattern: **MAR first, then memory**. Once you see it, the micro-operation table of the [control unit](control.md) becomes easy to read.

## Worked example: `ST A, [0xF0]` (B.1 at 0x0A)

| Step | Bus | Action | MAR after |
| --- | --- | --- | --- |
| T0 | PC = 0A | MAR ← 0A | 0A |
| T1 | M\[0A\] = 30 | IR0 ← 30, PC ← 0B | 0A |
| T2 | PC = 0B | MAR ← 0B | 0B |
| T3 | M\[0B\] = F0 | IR1 ← F0, PC ← 0C | 0B |
| T4 | IR1 = F0 | MAR ← F0 | **F0** |
| T5 | R\[rd\] = A = 0F | M\[F0\] ← 0F (the LEDs light up) | F0 |

## Common mistakes

| Symptom | Cause |
| --- | --- |
| Logisim reports oscillation as soon as the CPU runs | Memory address taken from the bus instead of the MAR |
| Loads read the instruction's own bytes | `mar_load` missing in T4, so the MAR still holds the address of byte 1 |
| MAR changes every cycle | Enable tied to 1 |

## Checklist (`tb_reg8`)

- [ ] `rst` = 1 with `load` = 1, `d` = 0x3C → `q` = 0x00.
- [ ] `load` = 1 → `q` follows `d` after each tick.
- [ ] `load` = 0, change `d`, tick → `q` unchanged.
