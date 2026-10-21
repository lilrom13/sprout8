# ALU — arithmetic and logic unit

> Specification: [module spec §9](../spec/sprout8-module-spec.md#9-alu--arithmetic-and-logic-unit) · Testbench: `tb_alu` · Logisim test vectors: `build/logisim/vectors/alu.txt` · Build order: 1 of 11 · Next: [PC](pc.md)

## What it does

The ALU computes. It takes two 8-bit numbers and a 3-bit operation code, and produces an 8-bit result plus three facts about it: is it zero (Z), did it carry or borrow (C), is bit 7 set (N).

It has **no clock and no memory**. Change an input and the outputs change immediately. That makes it the easiest module to build and test, and a good first circuit.

The ALU does not know about instructions. It does not know that INC exists, or that CMP throws its result away. The control unit and the CPU wiring arrange those (see "How the CPU uses it" below). The ALU only knows eight operations.

## Interface

```
              +-----------------+
    a[8] ---->|                 |----> y[8]
    b[8] ---->|       alu       |----> z
   op[3] ---->|                 |----> c
              |                 |----> n
              +-----------------+
```

| `op` | Name | `y` | `c` |
| --- | --- | --- | --- |
| 0 | ADD | (a + b) mod 256 | 1 if a + b > 255 (carry out) |
| 1 | SUB | (a − b) mod 256 | 1 if a < b (borrow) |
| 2 | AND | a AND b | 0 |
| 3 | OR | a OR b | 0 |
| 4 | XOR | a XOR b | 0 |
| 5 | SHL | a shifted left, bit 0 ← 0 | old a\[7\] |
| 6 | SHR | a shifted right, bit 7 ← 0 | old a\[0\] |
| 7 | PASB | b | 0 |

For every operation: `z` = 1 if `y` = 0x00, and `n` = `y[7]`.

## How it works inside

The design idea: **compute all eight results at the same time, then pick one** with a multiplexer. Do the same for the carry.

```
   a, b --> [ Adder      ] --y0--+         +--c0 (carry out)
   a, b --> [ Subtractor ] --y1--+         +--c1 (borrow out)
   a, b --> [ AND        ] --y2--+         +--0
   a, b --> [ OR         ] --y3--+         +--0
   a, b --> [ XOR        ] --y4--+         +--0
   a    --> [ wiring SHL ] --y5--+         +--a[7]
   a    --> [ wiring SHR ] --y6--+         +--a[0]
   b    -------------------y7--+         +--0
                               |           |
                          +----v----+ +----v----+
                    op -->|  MUX 8  | |  MUX 8  |<-- op
                          |  8 bits | |  1 bit  |
                          +----+----+ +----+----+
                               |           |
                               y           c
                               |
                  +------------+-----------+
                  |                        |
            [ 8-input NOR ]          [ bit 7 ]
                  |                        |
                  z                        n
```

### The arithmetic

- **ADD.** An 8-bit adder produces a 9-bit answer: 8 bits of sum plus a carry out. The carry out is exactly "the true sum was more than 255". Example: 0xFF + 0x01 = 0x100 → `y` = 0x00, `c` = 1, `z` = 1.
- **SUB.** Sprout-8's C after a subtraction means **borrow**: "a was smaller than b". Example: 0x03 − 0x05 = −2 → `y` = 0xFE (−2 mod 256), `c` = 1, `n` = 1. Logisim's Subtractor has a "borrow out" that already means exactly this, so wire it straight to the carry mux.

  Some CPUs (6502, ARM) use the opposite convention, where C = 1 means "no borrow". Sprout-8 does not. If you build SUB as `a + NOT b + 1` with an adder, you must **invert** the carry out to get the borrow.

### The logic operations

AND, OR and XOR work bit by bit, and nothing carries between bits, so C is always 0 after them. This is what conformance test C4 checks: `ADD` sets C, then `OR` must clear it.

### The shifts are just wires

Shifting left by one moves every bit up one place. In hardware that needs no gates, only wiring with two Splitters:

```
  SHL:   y[7:1] = a[6:0],  y[0] = 0,  c = a[7]       (the bit pushed out the top)
  SHR:   y[6:0] = a[7:1],  y[7] = 0,  c = a[0]       (the bit pushed out the bottom)
```

Example: SHR 0x81 (1000 0001) → `y` = 0x40 (0100 0000), `c` = 1. This is test C5.

### The flags

- **Z** is 1 only when all 8 bits of `y` are 0: an 8-input NOR gate, or an OR gate followed by NOT.
- **N** is simply `y[7]`. Read as a signed number, bit 7 is the sign, so N = 1 means "negative".
- **C** comes from the second multiplexer.

## Building it in Logisim

1. Create the subcircuit `alu`. Add input pins `a` (8 bits), `b` (8 bits), `op` (3 bits) and output pins `y` (8 bits), `z`, `c`, `n` (1 bit each). Use exactly these labels: the test vectors match pins by name.
2. Arithmetic library: an **Adder** and a **Subtractor**, both 8 bits. Leave carry-in and borrow-in unconnected (they default to 0) or tie them to a 0 Constant.
3. Gates library: **AND**, **OR** and **XOR** gates with *Data Bits* = 8.
4. Shifts: a **Splitter** on `a` with *fan out* 8, then a second Splitter (*fan in* 8) to rebuild the shifted byte, with a 1-bit 0 Constant on the empty bit.
5. Plexers library: a **Multiplexer** with *Select Bits* = 3 and *Data Bits* = 8 for `y`, and another with *Data Bits* = 1 for `c`. Put 1-bit 0 Constants on carry inputs 2, 3, 4 and 7.
6. Z: a Splitter on `y` into an 8-input **NOR** gate. N: a Splitter on `y`, take bit 7.

Logisim also has a **Shifter** component. It works, but the splitter version shows that a shift is only wiring, and it gives easy access to the bit shifted out.

## Testing it

```sh
make logisim     # writes build/logisim/vectors/alu.txt
```

In Logisim: select the `alu` circuit, **Simulate → Test Vector**, load `alu.txt`, and run. All 3,360 rows must pass. For the full 524,288-case sweep that `tb_alu` runs, generate with `python3 tools/gen_logisim_vectors.py --exhaustive` (slower).

Headless:

```sh
java -jar logisim-evolution.jar --test-vector alu build/logisim/vectors/alu.txt hw/logisim/sprout8.circ
```

## How the CPU uses it

The CPU connects `a` to register port A (R\[rd\]) and `b` to port B (R\[rs\]), with one twist: a 2:1 multiplexer in front of `b` can force the constant 0x01 when the control signal `alu_b_one` is set. With that, ten instructions use just seven operations:

| Instruction | `op` | `b` | Result written to R\[rd\]? | Flags written? |
| --- | --- | --- | --- | --- |
| ADD rd, rs | ADD | R\[rs\] | yes | yes |
| SUB rd, rs | SUB | R\[rs\] | yes | yes |
| AND / OR / XOR | AND / OR / XOR | R\[rs\] | yes | yes |
| CMP rd, rs | SUB | R\[rs\] | **no** | yes |
| INC rd | ADD | **0x01** | yes | yes |
| DEC rd | SUB | **0x01** | yes | yes |
| SHL rd / SHR rd | SHL / SHR | (ignored) | yes | yes |

- **CMP is a SUB whose answer is thrown away.** Only the flags are kept. After `CMP A, B`, Z = 1 means A = B and C = 1 means A < B. That is how `JE` (= JZ) and `JLO` (= JC) work.
- **INC's carry** is "the register was 0xFF and wrapped to 0x00". **DEC's carry** is "the register was 0x00 and wrapped to 0xFF". Both fall out of ADD/SUB with b = 1, so no extra logic is needed.

All of these take a single step (T4): the operands go in, the result comes out, and at the clock edge it is written to R\[rd\] and the flags at the same time.

**PASB** (op 7) is not used by any instruction in the reference control unit; it is there so that op 7 has a defined result. MOV does not go through the ALU: it sends R\[rs\] straight onto the bus.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| C3 fails: 03 − 05 gives C = 0 | Borrow inverted, or SUB built as `a + NOT b + 1` without inverting the carry |
| C4 fails: C still 1 after OR | Carry mux input 3 not tied to 0 |
| SHL/SHR results shifted the wrong way | Splitter bits swapped; check bit 0 is the least significant |
| Z = 1 for every result | NOR gate fed from `a` instead of `y` |
| Test vector: "pin not found" | Pin labels differ from `a b op y z c n` |
| Test vector: "too many bits" | Pin width wrong (`op` must be 3 bits) |

## Checklist

- [ ] All rows of `alu.txt` pass.
- [ ] By hand: `op`=0, 0xFF + 0x01 → `y`=00, `z c n` = 1 1 0 (C2).
- [ ] `op`=1, 0x03 − 0x05 → `y`=FE, `z c n` = 0 1 1 (C3).
- [ ] `op`=1, 0x05 − 0x05 → `z`=1, `c`=0.
- [ ] `op`=6, a = 0x81 → `y`=40, `c`=1 (C5).
