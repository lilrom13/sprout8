# The Sprout-8 Module Specification

**Volume II: Reference Implementation** · Document version 1.0-draft · Oct 21, 2026

## Preface

This document splits the reference multi-cycle implementation of Sprout-8 (ISA manual, Chapter 7) into hardware modules and specifies each one: its ports, its behavior, its internal structure and the checks it must pass. It is written so that each module can be built and tested on its own, in Logisim-evolution or in VHDL, and then assembled into a working CPU.

The ISA manual stays the source of truth for what software can observe. This volume is normative only for the module boundaries: two implementations that follow it can swap modules with each other, and the testbenches in `hw/tb/` check exactly these interfaces.

| Item | Value |
| --- | --- |
| Implements | Sprout-8 ISA v1.0 |
| Document version | 1.0-draft |
| Primary target | Logisim-evolution 3.9 or newer |
| Secondary target | VHDL-2008 (`hw/rtl/`, analysed in the order of `hw/manifest.json`) |

## 1. Overview

### 1.1 Module list

| # | Module | Kind | Testbench | Depends on |
| --- | --- | --- | --- | --- |
| 2 | Shared definitions | constants | (all) | – |
| 3 | `reg8` | sequential | `tb_reg8` | – |
| 4 | `pc` | sequential | `tb_pc` | – |
| 5 | `sp` | sequential | `tb_sp` | – |
| 6 | `flags` | sequential | `tb_flags` | – |
| 7 | `ir` | sequential | `tb_ir` | – |
| 8 | `regfile` | sequential | `tb_regfile` | `reg8` (or plain registers) |
| 9 | `alu` | combinational | `tb_alu` | – |
| 10 | `mem_io` | mixed | `tb_mem_io` | – |
| 11 | `control` | mixed | `tb_control` | – |
| 12 | `cpu` | top of core | `tb_cpu` | 3–9, 11 |
| 13 | `sprout8_board` | Logisim top level | manual, Appendix B programs | `cpu`, `mem_io` |

Build them in this order. Every module from 3 to 11 can be finished and tested before `cpu` exists.

### 1.2 Block diagram

```
                 +-------------------------------------------------------------+
                 |                           cpu                               |
                 |                                                             |
   +---------+   |  ctrl   +------------------------------------------------+  |
   | control |<--+---------|                8-bit BUS (mux)                 |  |
   | step    |   |         |  0:none 1:PC 2:SP 3:IR1 4:MEM 5:RD 6:RS 7:ALU   |  |
   | decoder |---+-------->+--+-----+-----+-----+-----+-----+-----+-----+----+  |
   +---------+   |         ^  |     ^     ^     ^     |     ^     ^     ^      |
     ^  ^  ^     |         |  v     |     |     |     v     |     |     |      |
     |  |  |     |       +----+  +----+ +-----+ |   +-----+ |   +---------+    |
   IR0  Z  C     |       | PC |  | SP | | IR  | |   | MAR | |   | regfile |    |
                 |       +----+  +----+ |0  1 | |   +-----+ |   | A B C D |    |
                 |                      +-----+ |      |    |   +---------+    |
                 |                              |      |    |    |port A|port B|
                 |                              |      |    |    v      v      |
                 |                              |      |    |  +-----------+   |
                 |                              |      |    +--|    ALU    |   |
                 |                              |      |       +-----------+   |
                 |                              |      |          | z c n      |
                 |                              |      |          v            |
                 |                              |      |       +-------+       |
                 |                              |      |       | flags |       |
                 +------------------------------+------+-------+-------+-------+
                                         mem_rdata|   |mem_addr  mem_wdata = BUS
                                                  |   v
                                          +----------------+
                                          |     mem_io     |--- LEDs, switches,
                                          | RAM 0x00-0xEF  |    TTY out, keyboard
                                          | I/O 0xF0-0xFF  |
                                          +----------------+
```

### 1.3 Conventions

These rules apply to every module unless its section says otherwise.

1. **One clock.** All state changes on the rising edge of `clk`. There are no other clocks and no latches.
2. **Active-high.** Every control input and output is active-high.
3. **Reset.** `rst` is synchronous and has the highest priority: after a rising edge with `rst = 1`, the module holds its reset value, whatever its other inputs are. RAM is the only state that reset does not change.
4. **Outputs are clean.** A register's output changes only just after a rising edge, never between edges (checked by `tb_flags` and `tb_regfile`).
5. **Combinational reads.** Every read path (register file ports, memory, I/O) is combinational: the data appears in the same clock cycle as the address. Nothing is read on a clock edge.
6. **Names.** Logisim pin labels MUST equal the port names in this document, so the same names show up in Logisim, in VHDL and in the testbench messages. Multi-bit ports are single buses of the stated width, bit 0 the least significant.
7. **Widths.** `byte` = 8 bits, `regsel` = 2 bits, `step` = 3 bits.

**Logisim notes.**

- Logisim-evolution registers have an asynchronous `Clear` input that resets to 0. For a register whose reset value is 0x00, wiring `rst` to `Clear` is acceptable: it also satisfies rule 3 when observed at clock edges.
- A register with a non-zero reset value (SP) MUST use a reset multiplexer instead: `D = rst ? RESET_VALUE : next`, `Enable = rst OR (normal enable)`.
- Keep every subcircuit's pins on the same sides (inputs left, outputs right, `clk`/`rst` bottom). It makes the `cpu` wiring much easier to read.

## 2. Shared definitions

These constants are shared by all modules. In VHDL they live in `hw/rtl/sprout8_pkg.vhd`; in Logisim they are the values of Constant components and ROM contents.

### 2.1 Reset values and port addresses

| Name | Value | Meaning |
| --- | --- | --- |
| `RESET_PC` | 0x00 | PC after reset |
| `RESET_SP` | 0xF0 | SP after reset |
| `PORT_LEDS` | 0xF0 | |
| `PORT_SWITCHES` | 0xF1 | |
| `PORT_TTY_OUT` | 0xF2 | |
| `PORT_TTY_STATUS` | 0xF3 | |
| `PORT_TTY_IN` | 0xF4 | |

### 2.2 ALU operation (`alu_op`, 3 bits)

This encoding is binding: `tb_alu` drives `op` with the numbers 0 to 7.

| Code | Name | Result `y` | Carry `c` |
| --- | --- | --- | --- |
| 000 | ADD | (a + b) mod 256 | 1 if a + b > 255 |
| 001 | SUB | (a − b) mod 256 | 1 if a < b (borrow) |
| 010 | AND | a AND b | 0 |
| 011 | OR | a OR b | 0 |
| 100 | XOR | a XOR b | 0 |
| 101 | SHL | (a × 2) mod 256, bit 0 ← 0 | a\[7\] |
| 110 | SHR | a div 2, bit 7 ← 0 | a\[0\] |
| 111 | PASB | b | 0 |

### 2.3 Bus source (`bus_src`, 3 bits)

| Code | Name | Drives the bus |
| --- | --- | --- |
| 000 | NONE | 0x00 (nothing selected) |
| 001 | PC | PC |
| 010 | SP | SP |
| 011 | IR1 | IR byte 1 (the operand byte) |
| 100 | MEM | `mem_rdata` |
| 101 | RD | register file port A (`R[rd]`) |
| 110 | RS | register file port B (`R[rs]`) |
| 111 | ALU | ALU result `y` |

### 2.4 Control word (`ctrl`, 21 bits)

The control unit produces one control word per clock cycle. The bit layout below is the layout of the microcode ROM (Section 11.5) and of the `ctrl` bus between `control` and `cpu`.

| Bits | Field | Effect when set (at the end of the cycle unless stated) |
| --- | --- | --- |
| 2:0 | `bus_src` | Selects the bus source (Section 2.3). Combinational |
| 3 | `mar_load` | MAR ← bus |
| 4 | `ir0_load` | IR byte 0 ← bus |
| 5 | `ir1_load` | IR byte 1 ← bus |
| 6 | `reg_we` | R\[rd\] ← bus |
| 7 | `pc_load` | PC ← bus |
| 8 | `mem_write` | M\[MAR\] ← bus |
| 9 | `mem_read` | Marks a real read of M\[MAR\]. The data is always visible; this strobe only triggers read side effects (TTY_IN) |
| 10 | `pc_inc` | PC ← PC + 1 |
| 11 | `sp_inc` | SP ← SP + 1 |
| 12 | `sp_dec` | SP ← SP − 1 |
| 13 | `flags_load` | Z, C, N ← ALU flags |
| 16:14 | `alu_op` | ALU operation (Section 2.2). Combinational. Don't-care unless `flags_load = 1` or `bus_src = ALU`; drive 000 then |
| 17 | `alu_b_one` | ALU input b ← 0x01 instead of R\[rs\] (INC, DEC). Combinational |
| 18 | `step_reset` | Last step of the instruction: the step counter returns to T0 |
| 19 | `halt` | Set the halted bit (HLT, illegal) |
| 20 | `illegal` | Set the illegal bit (reserved encodings) |

Bits 19 and 20 are used only inside `control`; the `ctrl` output that leaves `control` may carry them or not.

## 3. `reg8` — generic 8-bit register

Used as the MAR. A general load register with a reset value.

### 3.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `rst` | in | 1 | Synchronous reset |
| `load` | in | 1 | Load enable |
| `d` | in | 8 | Data in |
| `q` | out | 8 | Data out |
| `RESET_VALUE` | generic | 8 | Value after reset. VHDL: generic, default 0x00. Logisim: see 3.3 |

### 3.2 Behavior

| `rst` | `load` | `q` after the edge |
| --- | --- | --- |
| 1 | – | `RESET_VALUE` |
| 0 | 1 | `d` |
| 0 | 0 | `q` (hold) |

### 3.3 Implementation

One 8-bit Register component; `load` → Enable. Logisim subcircuits have no generics: build `reg8` with a reset value of 0x00 (rst → Clear). If you want the generic, add an 8-bit input `rst_val` and a reset multiplexer (Section 1.3) and wire a Constant to it.

### 3.4 Checks (`tb_reg8`)

- Reset gives `RESET_VALUE`, even with `load = 1`.
- All 256 values load; each value holds when `load = 0` and `d` changes.

## 4. `pc` — program counter

### 4.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `inc` | in | 1 | PC ← PC + 1 |
| `load` | in | 1 | PC ← `d` |
| `d` | in | 8 | Load value (from the bus) |
| `q` | out | 8 | Current PC |

### 4.2 Behavior

| `rst` | `load` | `inc` | `q` after the edge |
| --- | --- | --- | --- |
| 1 | – | – | `RESET_PC` (0x00) |
| 0 | 1 | – | `d` (**load beats inc**) |
| 0 | 0 | 1 | (`q` + 1) mod 256 (0xFF wraps to 0x00) |
| 0 | 0 | 0 | `q` |

### 4.3 Implementation

An 8-bit Register; an Adder (or an Incrementer built from an Adder with constant 1, carry-out ignored); a 2:1 mux on D selecting `d` when `load = 1`, else `q + 1`; Enable = `load OR inc`; `rst` → Clear.

### 4.4 Checks (`tb_pc`)

Reset beats load and inc; hold; 256 increments visit every value and wrap; any value loads; load beats inc; 0xFF + 1 = 0x00.

## 5. `sp` — stack pointer

### 5.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `inc` | in | 1 | SP ← SP + 1 |
| `dec` | in | 1 | SP ← SP − 1 |
| `q` | out | 8 | Current SP |

SP has no load input. It is only ever reset, incremented or decremented.

### 5.2 Behavior

| `rst` | `inc` | `dec` | `q` after the edge |
| --- | --- | --- | --- |
| 1 | – | – | `RESET_SP` (0xF0) |
| 0 | 1 | 0 | (`q` + 1) mod 256 |
| 0 | 0 | 1 | (`q` − 1) mod 256 |
| 0 | 1 | 1 | `q` (they cancel) |
| 0 | 0 | 0 | `q` |

### 5.3 Implementation

An 8-bit Register; an Adder whose b input is 0x01 when `inc`, 0xFF when `dec` (adding 0xFF is subtracting 1 mod 256); Enable = `rst OR (inc XOR dec)`; D = `rst ? 0xF0 : sum`. Do **not** use the Clear pin: it would reset to 0x00.

### 5.4 Checks (`tb_sp`)

Reset gives 0xF0, even with `dec = 1`; the first decrement gives 0xEF; 256 decrements wrap through 0x00 → 0xFF; 0xF0 + 16 increments = 0x00; 0x00 − 1 = 0xFF; inc and dec together hold.

## 6. `flags` — condition flags

### 6.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `load` | in | 1 | Latch all three flags |
| `z_in`, `c_in`, `n_in` | in | 1 each | From the ALU |
| `z`, `c`, `n` | out | 1 each | Stored flags |

### 6.2 Behavior

Reset clears all three (and beats `load`). When `load = 1`, all three are written together; when `load = 0`, all three hold. There is no way to write one flag alone (ISA 3.2: instructions that write flags always write all three).

### 6.3 Implementation

Three D flip-flops with a shared enable, or one 3-bit Register with a Splitter on each side.

### 6.4 Checks (`tb_flags`)

Reset with all inputs high clears Z C N; all 8 patterns load and hold while the inputs change; the outputs change only after the edge.

## 7. `ir` — instruction register

Two bytes, loaded separately during fetch, with the byte-0 fields decoded.

### 7.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `load0` | in | 1 | Byte 0 ← `d` (step T1) |
| `load1` | in | 1 | Byte 1 ← `d` (step T3) |
| `d` | in | 8 | From the bus |
| `ir0` | out | 8 | Byte 0 |
| `ir1` | out | 8 | Byte 1 (immediate / address) |
| `opcode` | out | 4 | `ir0[7:4]` |
| `rd` | out | 2 | `ir0[3:2]` |
| `rs` | out | 2 | `ir0[1:0]` |

### 7.2 Behavior

Reset clears both bytes. `load0` writes byte 0 only; `load1` writes byte 1 only; each byte holds otherwise. `opcode`, `rd` and `rs` are pure wiring from `ir0`.

### 7.3 Implementation

Two 8-bit Registers sharing `d`; one Splitter on `ir0` (fan-out 3, bit groups 7–4, 3–2, 1–0).

### 7.4 Checks (`tb_ir`)

Reset clears both bytes even with both loads set; all 256 values of byte 0 load with correct fields and leave byte 1 alone; all 256 values of byte 1 load and leave byte 0 alone; hold.

## 8. `regfile` — register file A, B, C, D

Four 8-bit registers with one write port and two combinational read ports.

### 8.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `we` | in | 1 | Write enable |
| `waddr` | in | 2 | Register to write (00 = A … 11 = D) |
| `wdata` | in | 8 | Value to write (from the bus) |
| `raddr_a` | in | 2 | Port A select (connected to `rd`) |
| `raddr_b` | in | 2 | Port B select (connected to `rs`) |
| `rdata_a` | out | 8 | R\[`raddr_a`\], combinational |
| `rdata_b` | out | 8 | R\[`raddr_b`\], combinational |
| `contents` | out | 4 × 8 | All four registers for debug. Logisim: four outputs `q_a`, `q_b`, `q_c`, `q_d` |

### 8.2 Behavior

- Reset clears A–D to 0x00 and beats a write in the same cycle.
- When `we = 1`, R\[`waddr`\] ← `wdata` at the edge; the other three registers hold.
- Both read ports may select any register, including the same one.
- **Read during write:** a port that reads the register being written shows the old value until the edge and the new value after it. This falls out naturally from edge-triggered registers; do not add a bypass.

### 8.3 Implementation

- A 2-to-4 Decoder on `waddr`; each output AND `we` drives one register's Enable.
- `wdata` goes to all four D inputs.
- Two 4:1 Multiplexers (8 bits wide), selects `raddr_a` and `raddr_b`.

### 8.4 Checks (`tb_regfile`)

Reset values on both ports; each register written with a distinct value and every (port A, port B) pair read back; `we = 0` writes nothing; a write touches only its register; read-during-write timing; reset beats write; 2,000 random cycles against a model.

## 9. `alu` — arithmetic and logic unit

Purely combinational. No clock, no state.

### 9.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `a` | in | 8 | First operand (R\[rd\]) |
| `b` | in | 8 | Second operand (R\[rs\], or 0x01 for INC/DEC) |
| `op` | in | 3 | Operation, Section 2.2 |
| `y` | out | 8 | Result |
| `z` | out | 1 | 1 if `y` = 0x00 |
| `c` | out | 1 | Carry/borrow, per Section 2.2 |
| `n` | out | 1 | `y[7]` |

### 9.2 Behavior

Exactly the table in Section 2.2. `z` and `n` are always computed from `y`, for every operation. The ALU knows nothing about instructions: INC is ADD with b = 1, DEC is SUB with b = 1, CMP is SUB whose result is not written back. The `cpu` and `control` modules arrange that.

### 9.3 Implementation

| Unit | Logisim component | Notes |
| --- | --- | --- |
| ADD | Adder, 8 bits | Carry-in 0; carry-out → c |
| SUB | Subtractor, 8 bits | Borrow-in 0; borrow-out → c (it is already "a < b", do not invert) |
| AND, OR, XOR | 8-bit gates | c = 0 |
| SHL | Splitters: `y = a[6:0] & 0`, c = `a[7]` | Pure wiring, no gates |
| SHR | Splitters: `y = 0 & a[7:1]`, c = `a[0]` | Pure wiring, no gates |
| PASB | wire `b` | c = 0 |

Then:

- An 8-input Multiplexer (8 bits wide, select = `op`) picks `y`.
- A second 8-input Multiplexer (1 bit wide, same select) picks `c`. Wire constant 0 into inputs 2, 3, 4 and 7.
- `z` = NOR of the 8 bits of `y` (an 8-input NOR, or OR then NOT).
- `n` = bit 7 of `y`, through a Splitter.

### 9.4 Checks (`tb_alu`)

Edge cases C2–C5 (FF + 01, 03 − 05, 05 − 05, OR, SHR 0x81, SHL 0x80, INC FF, DEC 00), then the exhaustive sweep: every op × every a × every b, 524,288 cases, against an integer model.

## 10. `mem_io` — memory and I/O

240 bytes of RAM plus the memory-mapped ports. The terminal, keyboard, switches and LEDs are **outside** this module (on the board), connected through ports, so the module can be tested without them.

### 10.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | `rst` resets the I/O registers only, never the RAM |
| `addr` | in | 8 | From the MAR |
| `wdata` | in | 8 | From the bus |
| `we` | in | 1 | Write strobe (`mem_write`) |
| `re` | in | 1 | Read strobe (`mem_read`). Only enables read side effects |
| `rdata` | out | 8 | Data at `addr`, combinational, valid whatever `re` is |
| `leds` | out | 8 | LEDS register |
| `switches` | in | 8 | Switch inputs |
| `tty_out_data` | out | 8 | Byte for the terminal (= `wdata`) |
| `tty_out_valid` | out | 1 | 1 during a cycle that writes TTY_OUT; the terminal takes the byte at the edge |
| `tty_in_data` | in | 8 | Key at the head of the keyboard queue |
| `tty_in_valid` | in | 1 | 1 if a key is waiting |
| `tty_in_ack` | out | 1 | 1 during a cycle that consumes the key; the keyboard drops it at the edge |
| `INIT_FILE` | generic | – | VHDL only: image preloaded into RAM. Logisim: the RAM's saved contents or a loaded image |

### 10.2 Address decode

`io = addr[7] AND addr[6] AND addr[5] AND addr[4]` (addr ≥ 0xF0). For the port number use `addr[3:0]`.

### 10.3 Read data (`rdata`)

| Address | `rdata` |
| --- | --- |
| 0x00–0xEF | RAM\[addr\] |
| 0xF0 LEDS | LEDS register |
| 0xF1 SWITCHES | `switches` |
| 0xF2 TTY_OUT | 0x00 |
| 0xF3 TTY_STATUS | `0000000` & `tty_in_valid` |
| 0xF4 TTY_IN | `tty_in_data` if `tty_in_valid`, else 0x00 |
| 0xF5–0xFF | 0x00 |

### 10.4 Writes and strobes

| Signal | Equation |
| --- | --- |
| RAM write enable | `we AND NOT io` (I/O writes never reach RAM) |
| LEDS load | `we AND addr = 0xF0`. LEDS resets to 0x00 |
| `tty_out_valid` | `we AND addr = 0xF2 AND NOT rst` |
| `tty_out_data` | `wdata` |
| `tty_in_ack` | `re AND addr = 0xF4 AND tty_in_valid` |

Writes to 0xF1 and 0xF3–0xFF are discarded. Only a strobed read (`re = 1`) of 0xF4 consumes a key; reading 0xF4 with `re = 0`, or reading 0xF3, does not.

### 10.5 Implementation

**RAM.** One RAM component, 8 address bits × 8 data bits. It is 256 bytes, but 0xF0–0xFF is never written or read.

- Set the data interface to separate load and store ports.
- Tie the load / output-enable input high, so `rdata` is always driven.
- Store = RAM write enable; clock = `clk`.
- Check in your Logisim version that the read output follows the address without a clock edge.

**I/O.**

- LEDS: an 8-bit Register.
- Port select: a 4-to-16 Decoder on `addr[3:0]`, enabled by `io`, gives one select line per port.
- Read data: a 2:1 mux (select `io`) between the RAM output and the I/O read value. The I/O read value is a 16-input mux on `addr[3:0]`, with constant 0x00 on unused inputs.

### 10.6 Checks (`tb_mem_io`)

- The init image loads, and unwritten bytes are 0x00.
- Reset clears LEDS but not RAM.
- Every RAM address reads back (a pattern and its inverse); `we = 0` writes nothing.
- Writes to 0xF0–0xFF do not alias into RAM, and the sweep strobes TTY_OUT exactly once.
- LEDS output and readback; SWITCHES for all 256 values, with writes ignored.
- TTY_OUT: one strobe per write, reads as 0x00, no strobe in reset.
- TTY_STATUS and TTY_IN with and without a key; no ack without `re`, or for TTY_STATUS.
- Reserved ports read as 0x00.

## 11. `control` — control unit

A step counter, the halted and illegal bits, and a decoder that turns (IR0, step, Z, C) into the control word.

### 11.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `ir0` | in | 8 | Instruction byte 0 (from `ir`) |
| `z`, `c` | in | 1 each | Stored flags (for conditional jumps) |
| `ctrl` | out | 21 | Control word, Section 2.4 |
| `step` | out | 3 | Current step, 0 = T0 … 7 = T7 |
| `halted` | out | 1 | Halted bit |
| `illegal` | out | 1 | Illegal bit (halted by a reserved encoding) |

### 11.2 State and sequencing

| State | Reset | Next value |
| --- | --- | --- |
| `step` | 0 | If `halted`: hold. Else if `step_reset`: 0. Else `step` + 1 |
| `halted` | 0 | Set by `halt`; stays 1 until reset |
| `illegal` | 0 | Set by `illegal`; stays 1 until reset |

While `halted = 1`, the `ctrl` output MUST be all zeros (no bus source, no loads, no memory access) and `step` is frozen. Only `rst` leaves the halted state.

Implementation:

- `step`: a 3-bit Register, Enable = NOT `halted`, D = `step_reset ? 0 : step + 1`.
- `halted` and `illegal`: two D flip-flops (or SR latches clocked by `clk`) with `rst` → Clear.
- `ctrl` output: AND each decoded bit with NOT `halted`.

### 11.3 Micro-operation table

This table is the whole behavior of the decoder. It restates ISA 7.2 in terms of the control word. A blank bus means `bus_src = NONE`. `end` is `step_reset`.

**Fetch, identical for every instruction (T0–T3 MUST NOT depend on `ir0`):**

| Step | bus | Other signals |
| --- | --- | --- |
| T0 | PC | `mar_load` |
| T1 | MEM | `ir0_load`, `mem_read`, `pc_inc` |
| T2 | PC | `mar_load` |
| T3 | MEM | `ir1_load`, `mem_read`, `pc_inc` |

**Execute:**

| Instruction | T4 | T5 | T6 | T7 |
| --- | --- | --- | --- | --- |
| NOP (00, f=0) | `end` | | | |
| HLT (00, f=1) | `end halt` | | | |
| RET (00, f=2) | SP: `mar_load` | MEM: `pc_load mem_read` | `sp_inc end` | |
| reserved (00, f=3) | `end halt illegal` | | | |
| LDI (1) | IR1: `reg_we end` | | | |
| LD (2) | IR1: `mar_load` | MEM: `reg_we mem_read end` | | |
| ST (3) | IR1: `mar_load` | RD: `mem_write end` | | |
| LDR (4) | RS: `mar_load` | MEM: `reg_we mem_read end` | | |
| STR (5) | RS: `mar_load` | RD: `mem_write end` | | |
| MOV (6) | RS: `reg_we end` | | | |
| ADD…XOR (7–B) | ALU: `reg_we flags_load end`, alu_op per 11.4 | | | |
| CMP (C) | `flags_load end`, alu_op = SUB | | | |
| INC (D, f=0) | ALU: `reg_we flags_load alu_b_one end`, ADD | | | |
| DEC (D, f=1) | ALU: `reg_we flags_load alu_b_one end`, SUB | | | |
| SHL (D, f=2) | ALU: `reg_we flags_load end`, SHL | | | |
| SHR (D, f=3) | ALU: `reg_we flags_load end`, SHR | | | |
| Jcc taken (E) | IR1: `pc_load end` | | | |
| Jcc not taken (E) | `end` | | | |
| PUSH (F, f=0) | `sp_dec` | SP: `mar_load` | RD: `mem_write end` | |
| POP (F, f=1) | SP: `mar_load` | MEM: `reg_we mem_read` | `sp_inc end` | |
| CALL (F, f=2) | `sp_dec` | SP: `mar_load` | PC: `mem_write` | IR1: `pc_load end` |
| reserved (F, f=3) | `end halt illegal` | | | |

`f` is the rs field (`ir0[1:0]`). The jump condition, from the rd field (`ir0[3:2]`):

```
taken = (rd = 00) OR (rd = 01 AND z) OR (rd = 10 AND NOT z) OR (rd = 11 AND c)
```

Cycle counts follow from the table: 4 fetch steps plus the execute steps (5 for one-step instructions, 6 for LD/ST/LDR/STR, 7 for PUSH/POP/RET, 8 for CALL).

### 11.4 ALU operation decode

| Opcode | f | `alu_op` |
| --- | --- | --- |
| 7 ADD | – | 000 ADD |
| 8 SUB | – | 001 SUB |
| 9 AND | – | 010 AND |
| A OR | – | 011 OR |
| B XOR | – | 100 XOR |
| C CMP | – | 001 SUB |
| D | 00 INC | 000 ADD |
| D | 01 DEC | 001 SUB |
| D | 10 SHL | 101 SHL |
| D | 11 SHR | 110 SHR |
| others | – | 000 (unused) |

### 11.5 Implementation option A: microcode ROM (recommended first)

A single ROM holds the whole table.

| ROM address bit | Source |
| --- | --- |
| 12:5 | `ir0[7:0]` |
| 4 | `z` |
| 3 | `c` |
| 2:0 | `step` |

The ROM is 13 address bits × 21 data bits (8,192 words), laid out as in Section 2.4. Unused steps of an instruction hold 0. Rows T0–T3 are the fetch words in every block of 8. Wire the jump condition into the address (`z`, `c`) rather than computing it with gates, so the ROM is the only decoder.

Generate the ROM image with a script (`tools/gen_microcode.py`) from the table in 11.3. Do not type 8,192 words by hand. Load it into the ROM component (Logisim: right-click → Load Image, format `v3.0 hex words addressed`).

### 11.6 Implementation option B: hardwired decoder

The same table as gates, which is better for learning how a decoder works. Use it as a second version once option A works, and test both against the same checks.

**Step and instruction decodes:**

- Steps: a 3-to-8 Decoder on `step` gives `T0` … `T7`; name `E4..E7` = `T4..T7`.
- Opcodes: a 4-to-16 Decoder on `opcode` gives `OP0` … `OPF`.
- Functions: a 2-to-4 Decoder on `f` gives `F0` … `F3`.

```
NOP  = OP0·F0    HLT  = OP0·F1    RET  = OP0·F2
PUSH = OPF·F0    POP  = OPF·F1    CALL = OPF·F2
ILL  = (OP0 + OPF)·F3
LDI = OP1  LD = OP2  ST = OP3  LDR = OP4  STR = OP5  MOV = OP6
ALU2 = OP7 + OP8 + OP9 + OPA + OPB          (two-operand ALU)
CMP = OPC   UN = OPD   JMP = OPE
ALUW  = ALU2 + UN                           (ALU result written to R[rd])
TAKEN = JMP · taken
```

**Control signals:**

```
mar_load   = T0 + T2 + E4·(RET + LD + ST + LDR + STR + POP) + E5·(PUSH + CALL)
ir0_load   = T1
ir1_load   = T3
mem_read   = T1 + T3 + E5·(RET + LD + LDR + POP)
pc_inc     = T1 + T3
mem_write  = E5·(ST + STR) + E6·(PUSH + CALL)
pc_load    = E4·TAKEN + E5·RET + E7·CALL
reg_we     = E4·(LDI + MOV + ALUW) + E5·(LD + LDR + POP)
sp_dec     = E4·(PUSH + CALL)
sp_inc     = E6·(RET + POP)
flags_load = E4·(ALUW + CMP)
alu_b_one  = E4·UN·(F0 + F1)
step_reset = E4·(NOP + HLT + ILL + LDI + MOV + ALU2 + CMP + UN + JMP)
           + E5·(LD + ST + LDR + STR)
           + E6·(RET + PUSH + POP)
           + E7·CALL
halt       = E4·(HLT + ILL)
illegal    = E4·ILL
```

**Bus source.** First compute one "drives the bus" line per source. At most one of them is 1 in any step:

```
drv_PC  = T0 + T2 + E6·CALL
drv_SP  = E4·(RET + POP) + E5·(PUSH + CALL)
drv_IR1 = E4·(LDI + LD + ST + TAKEN) + E7·CALL
drv_MEM = T1 + T3 + E5·(RET + LD + LDR + POP)
drv_RD  = E5·(ST + STR) + E6·PUSH
drv_RS  = E4·(LDR + STR + MOV)
drv_ALU = E4·ALUW
```

Then encode them into 3 bits (or use a Priority Encoder):

```
bus_src[0] = drv_PC + drv_IR1 + drv_RD + drv_ALU     (codes 1, 3, 5, 7)
bus_src[1] = drv_SP + drv_IR1 + drv_RS + drv_ALU     (codes 2, 3, 6, 7)
bus_src[2] = drv_MEM + drv_RD + drv_RS + drv_ALU     (codes 4, 5, 6, 7)
```

`alu_op`: the table in 11.4, built as a small ROM (5 address bits: opcode and f), or as an 8-input mux on `opcode[2:0]` plus a 4-input mux for opcode D.

### 11.7 Checks (`tb_control`)

- For all 256 values of byte 0 × all 4 Z/C combinations, the control word at every step equals the table in 11.3.
- T0–T3 do not depend on `ir0` (the bench puts junk in it during fetch).
- The cycle count of every instruction is correct.
- `step` counts 0, 1, 2, … and returns to 0 after `end`.
- HLT and the reserved encodings halt; `ctrl` is all zero and `step` is frozen while halted; only reset clears `halted`.
- `illegal` is set for the reserved encodings only.

## 12. `cpu` — the processor core

Instantiates every module above except `mem_io`, and wires them around the bus.

### 12.1 Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | |
| `mem_addr` | out | 8 | MAR output |
| `mem_wdata` | out | 8 | The bus |
| `mem_rdata` | in | 8 | From `mem_io` |
| `mem_we` | out | 1 | `ctrl.mem_write` |
| `mem_re` | out | 1 | `ctrl.mem_read` |
| `halted` | out | 1 | From `control` |
| `illegal` | out | 1 | From `control` |
| `dbg_pc`, `dbg_sp` | out | 8 | PC, SP |
| `dbg_a`, `dbg_b`, `dbg_c`, `dbg_d` | out | 8 | Register file contents |
| `dbg_z`, `dbg_cf`, `dbg_n` | out | 1 | Flags (`dbg_cf` is the carry flag; `dbg_c` is register C) |
| `dbg_ir0` | out | 8 | IR byte 0 |
| `dbg_retire` | out | 1 | `ctrl.step_reset`: 1 during the last step of each instruction |
| `dbg_step` | out | 3 | Optional, for a display on the board |

### 12.2 Wiring

| Destination | Source |
| --- | --- |
| Bus mux input 0 | constant 0x00 |
| Bus mux input 1 / 2 / 3 | `pc.q` / `sp.q` / `ir.ir1` |
| Bus mux input 4 | `mem_rdata` |
| Bus mux input 5 / 6 | `regfile.rdata_a` / `regfile.rdata_b` |
| Bus mux input 7 | `alu.y` |
| Bus mux select | `ctrl.bus_src` |
| `pc.d`, `reg8(MAR).d`, `ir.d`, `regfile.wdata`, `mem_wdata` | bus |
| `pc.load`, `pc.inc` | `ctrl.pc_load`, `ctrl.pc_inc` |
| `sp.inc`, `sp.dec` | `ctrl.sp_inc`, `ctrl.sp_dec` |
| `mar.load` | `ctrl.mar_load` |
| `ir.load0`, `ir.load1` | `ctrl.ir0_load`, `ctrl.ir1_load` |
| `regfile.we`, `regfile.waddr` | `ctrl.reg_we`, `ir.rd` |
| `regfile.raddr_a`, `regfile.raddr_b` | `ir.rd`, `ir.rs` |
| `alu.a` | `regfile.rdata_a` |
| `alu.b` | `ctrl.alu_b_one ? 0x01 : regfile.rdata_b` (a 2:1 mux) |
| `alu.op` | `ctrl.alu_op` |
| `flags.z_in/c_in/n_in`, `flags.load` | `alu.z/c/n`, `ctrl.flags_load` |
| `control.ir0`, `control.z`, `control.c` | `ir.ir0`, `flags.z`, `flags.c` |
| `mem_addr` | `mar.q` |

Use one 8-input Multiplexer for the bus, not tri-state buffers. Use a Splitter to break `ctrl` into named fields once, next to the `control` instance, and label each wire with the field name.

### 12.3 Checks (`tb_cpu`)

- C1 reset state.
- Programs B.1–B.3 with exact results and cycle counts: B.1 gives LEDS = 0x0F in 96 cycles; B.2 prints `HI!` in 172 cycles with SP back at 0xF0; B.3 echoes `ok!` and consumes each key once.
- Conformance tests C2–C16.
- No memory activity while halted.
- Random programs run in lockstep with the golden model, comparing all architectural state after every instruction.

## 13. `sprout8_board` — Logisim top level

Not part of the VHDL design. This is the circuit students run.

| Element | Logisim component | Connection |
| --- | --- | --- |
| Clock | Clock | `clk` of `cpu` and `mem_io`, and the clocks of TTY and Keyboard |
| Reset | Button (plus an optional "reset at start" Pin) | `rst` of `cpu` and `mem_io` |
| Core | `cpu` | |
| Memory | `mem_io` | `addr` ← `mem_addr`, `wdata` ← `mem_wdata`, `we` ← `mem_we`, `re` ← `mem_re`, `mem_rdata` ← `rdata` |
| LEDs | 8 LEDs (bit 0 on the right) | `leds` |
| Switches | DIP Switch, 8 | `switches` |
| Terminal | TTY | Data ← `tty_out_data[6:0]`, Write enable ← `tty_out_valid` |
| Keyboard | Keyboard | `tty_in_data` ← Data zero-extended to 8 bits; `tty_in_valid` ← Available; Read enable ← `tty_in_ack` |
| Status | 2 LEDs | HALTED ← `halted`, ILLEGAL ← `illegal` (ISA 5.4) |
| Displays | Hex Digit Displays | PC, SP, A, B, C, D, IR0, step |

**Loading a program.** Convert a `.hex` file from `sw/programs/` to a Logisim image (`tools/hex2logisim.py`), then right-click the RAM inside `mem_io` → Load Image. Reset, then run the clock. Compare the step-by-step state with `python3 sw/emulator/sprout8.py <prog.hex> --trace`.

## Appendix A. Signal summary

Every signal between modules, for wiring and for probing.

| Signal | Width | From | To |
| --- | --- | --- | --- |
| bus | 8 | bus mux in `cpu` | pc, mar, ir, regfile, `mem_wdata` |
| `ctrl` | 21 | control | cpu (all modules) |
| `step` | 3 | control | debug |
| `ir0` | 8 | ir | control |
| `ir1` | 8 | ir | bus mux |
| `rd`, `rs` | 2 each | ir | regfile |
| `rdata_a`, `rdata_b` | 8 each | regfile | alu, bus mux |
| `y`; `z c n` | 8; 1 each | alu | bus mux; flags |
| `z`, `c` (stored) | 1 each | flags | control |
| `mem_addr` | 8 | mar | mem_io |
| `mem_rdata` | 8 | mem_io | bus mux |
| `mem_we`, `mem_re` | 1 each | control (through cpu) | mem_io |

## Appendix B. Common mistakes

| Symptom | Likely cause |
| --- | --- |
| SP is 0x00 after reset | SP reset through the Clear pin. Use the reset mux (Section 5.3) |
| IR0 loads the wrong byte in T1 | RAM read is clocked, or its output enable is not tied high (Section 10.5) |
| B.1 runs but takes more than 96 cycles | An instruction takes an extra step; check `end` in the table (11.3) |
| CMP changes a register | `reg_we` set for opcode C |
| LD changes the flags | `flags_load` set outside ALU/CMP/unary instructions |
| `JNZ` loops forever in B.1 | DEC does not write flags, or `alu_b_one` is missing so DEC subtracts R\[A\] |
| B.3 prints each key twice or never | `tty_in_ack` not gated by `re`, or by the address |
| A write to 0xF0 also changes RAM | RAM write enable not gated by `NOT io` |
| Garbage after HLT | `ctrl` not forced to zero while halted |
| Bus shows red (error) in Logisim | Two sources wired onto one bus; use the bus multiplexer |
