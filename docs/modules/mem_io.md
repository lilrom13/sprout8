# Memory and I/O (`mem_io`)

> Specification: [module spec §10](../spec/sprout8-module-spec.md#10-mem_io--memory-and-io) · Testbench: `tb_mem_io` · Build order: 5 of 11 · Previous: [IR](ir.md) · Next: [Register file](regfile.md)

## What it does

`mem_io` is everything the CPU sees at the end of its address and data wires: **240 bytes of RAM** for code, data and the stack, and **16 I/O ports** at the top of the address space. The CPU does not know the difference. It reads and writes addresses; this module decides whether an address means RAM or a device.

This is called **memory-mapped I/O**. There are no IN/OUT instructions: `ST A, [0xF0]` lights the LEDs because address 0xF0 *is* the LEDs.

## The memory map

```
 0xFF +----------------------+
      |  I/O ports           |  0xF0 LEDS  0xF1 SWITCHES  0xF2 TTY_OUT
 0xF0 +----------------------+  0xF3 TTY_STATUS  0xF4 TTY_IN  0xF5-FF reserved
 0xEF |  stack (grows down)  |
      |          v           |
      |  code and data       |
 0x00 +----------------------+
```

| Address | Read gives | Write does |
| --- | --- | --- |
| 0x00–0xEF | RAM byte | RAM byte ← data |
| 0xF0 LEDS | the last value written | LEDs ← data |
| 0xF1 SWITCHES | the 8 switches | nothing |
| 0xF2 TTY_OUT | 0x00 | send a character to the terminal |
| 0xF3 TTY_STATUS | bit 0 = 1 if a key is waiting | nothing |
| 0xF4 TTY_IN | the waiting key (and removes it), or 0x00 | nothing |
| 0xF5–0xFF | 0x00 | nothing |

## Interface

```
                 +---------------------+
     addr[8] --->|                     |---> rdata[8]
    wdata[8] --->|                     |---> leds[8]
          we --->|       mem_io        |---> tty_out_data[8]
          re --->|                     |---> tty_out_valid
 switches[8] --->|                     |---> tty_in_ack
tty_in_data[8]-->|                     |
tty_in_valid --->|                     |
                 +---------------------+
                   clk ^     rst ^
```

The terminal, keyboard, switches and LEDs themselves live on the [board](board.md), outside this module. That keeps `mem_io` testable on its own, and lets the VHDL testbench replace them with models.

## Two rules about timing

### Rule 1: reading is instant, writing happens at the clock edge

`rdata` must follow `addr` **without waiting for a clock edge**, the way a combinational circuit would. Here is why. In T1 the CPU does `IR0 ← M[MAR]` in one step: during that cycle the bus must already carry the memory byte, so that IR0 can capture it at the end of the cycle. If memory only produced its data at a clock edge, IR0 would capture stale data.

Writes are the opposite: they happen at the rising edge when `we` = 1, like every register.

### Rule 2: `re` is not "output enable"

`rdata` is valid **whatever `re` is**. The `re` strobe (`mem_read` from the control unit) only says "this is a real read by an instruction". Only one thing in the system cares about that: TTY_IN, which removes the key from the keyboard queue when it is read. An address match alone must not consume a key. For example, `ST A, [0xF4]` puts 0xF4 on the address lines for a write; it must be ignored, not eat the waiting key.

## How it works inside

```
 addr ---+-----------------------------> [ RAM 256 x 8 ] --- ram_out --+
         |                                 ^ str = we AND NOT io        |
         |                                 ^ data in = wdata            |  0
         |                                                         +----v----+
         +--> [ addr >= 0xF0 ? ] -- io -------------------------->| MUX 2:1 |--> rdata
         |                                                         +----^----+
         +--> [ 4-to-16 decoder on addr[3:0], enabled by io ]          |  1
                 |                                                      |
                 +-- sel_F0 -- LEDS register (load = we AND sel_F0) -+  |
                 +-- sel_F2 -- tty_out_valid = we AND sel_F2 AND NOT rst
                 +-- sel_F4 -- tty_in_ack = re AND sel_F4 AND tty_in_valid
                                                                      |
     [ 16-input MUX on addr[3:0] ]  F0: LEDS  F1: switches  F2: 00    |
                                    F3: 0000000 & tty_in_valid        |
                                    F4: tty_in_valid ? tty_in_data:00 |
                                    F5..FF: 00  ------- io_out -------+
```

### Address decoding

`io` = 1 when the top four address bits are all 1 (addr ≥ 0xF0): a 4-input AND on `addr[7:4]`. The low four bits `addr[3:0]` then pick the port.

### RAM

Logisim's RAM component has 256 locations when given 8 address bits. Only 0x00–0xEF are used. The write enable is `we AND NOT io`, so **a store to an I/O address never changes RAM** (`tb_mem_io` checks every port). Reset does **not** clear RAM: a program loaded into RAM survives pressing reset.

### LEDS

An 8-bit register, loaded when `we` = 1 and the address is 0xF0, reset to 0x00. Its output drives both the `leds` port and input 0 of the I/O read multiplexer, which is how a program can read back what it wrote (test C15).

### Terminal output (TTY_OUT)

`tty_out_valid` = `we` AND address 0xF2 AND NOT `rst`. It is high during the cycle of a store to 0xF2, and the terminal on the board takes `tty_out_data` (= `wdata`) at the clock edge. One store prints exactly one character.

### Keyboard input (TTY_STATUS, TTY_IN)

The keyboard on the board holds a queue of typed keys. It shows the first one on `tty_in_data`, and sets `tty_in_valid` when the queue is not empty.

- Reading 0xF3 gives `0000000` followed by `tty_in_valid`: "is there a key?"
- Reading 0xF4 gives the key, and `tty_in_ack` tells the keyboard to drop it at the clock edge, so the next read sees the next key. `tty_in_ack` needs all three: `re` (a real read), address 0xF4, and a key actually waiting.

## Building it in Logisim

1. Create the subcircuit `mem_io` with the pins above.
2. Memory library: a **RAM** with *Address Bit Width* 8, *Data Bit Width* 8, and the data interface set to **separate load and store ports**.
   - Address ← `addr`, data in ← `wdata`, store ← `we AND NOT io`, clock ← `clk`.
   - Tie the load / output-enable input to constant 1 so the output is always driven (Rule 2).
   - Label the RAM `ram`. Headless runs use `--load <image> ram`; without a label, Logisim would load the image into every RAM and ROM.
   - Check that the output follows the address without a clock edge (Rule 1).
3. A 4-input **AND** on the top 4 address bits gives `io`.
4. A **Decoder** (Plexers library), 4 select bits, with its enable ← `io`, gives the per-port select lines.
5. The LEDS **Register** and the gates for `tty_out_valid` and `tty_in_ack`.
6. A 16-input **Multiplexer** (4 select bits, 8 data bits) for the I/O read value, with 0x00 Constants on the unused inputs, and a 2:1 multiplexer between RAM and I/O selected by `io`.

### Loading a program

```sh
make logisim           # build/logisim/b1_sum_leds.img, b2_..., b3_...
```

Right-click the RAM (you may need to open `mem_io` from inside the running circuit to see it) → **Load Image…**, pick the `.img` file. The RAM contents are also saved inside the `.circ` file.

## How the CPU uses it

| Strobe | When | Steps |
| --- | --- | --- |
| `mem_read` | fetch, and every load | T1, T3; T5 of LD, LDR, POP, RET |
| `mem_write` | every store | T5 of ST, STR; T6 of PUSH, CALL |

There is at most one memory access per step, and the address always comes from the [MAR](reg8.md).

## Worked example: B.3 echo

```
00: 14 01     LDI  B, #1
02: 20 F3     wait: LD  A, [TTY_STATUS]
04: 91 00     AND  A, B
06: E4 02     JZ   wait
08: 20 F4     LD   A, [TTY_IN]
0A: 30 F2     ST   A, [TTY_OUT]
0C: E0 02     JMP  wait
```

With the key `k` (0x6B) typed:

| Instruction | Address | `rdata` | Effect |
| --- | --- | --- | --- |
| LD A, \[F3\] | F3 | 01 | a key is waiting |
| AND A, B | – | – | A = 01, Z = 0, so JZ falls through |
| LD A, \[F4\] | F4 | 6B | `tty_in_ack` = 1 in T5, the keyboard drops `k` |
| ST A, \[F2\] | F2 | – | `tty_out_valid` = 1 in T5, the terminal prints `k` |
| LD A, \[F3\] | F3 | 00 | queue empty, loop |

Note the `AND A, B`. **LD does not change the flags**, so the status byte must pass through the ALU before `JZ` can test it.

## Common mistakes

| Symptom | Cause |
| --- | --- |
| IR loads garbage or the previous byte | RAM output clocked or not always enabled (Rule 1, Rule 2) |
| `ST A, [0xF0]` also changes RAM\[0xF0\] | RAM store not gated with `NOT io`; C14 fails |
| Every key is printed twice, or keys disappear | `tty_in_ack` not gated with `re` or with the address |
| Terminal prints a character on reset | `tty_out_valid` not gated with `NOT rst` |
| Program gone after reset | RAM wired to `rst` (it must not be) |

## Checklist (`tb_mem_io`)

- [ ] Write then read back a few RAM addresses, including 0x00 and 0xEF.
- [ ] Write to 0xF0 → `leds` changes and reading 0xF0 returns the value; RAM is unchanged.
- [ ] Reset → `leds` = 0x00, RAM unchanged.
- [ ] Reading 0xF1 follows `switches`; writing it does nothing.
- [ ] One write to 0xF2 → `tty_out_valid` high for one cycle; reading 0xF2 gives 0x00.
- [ ] With `tty_in_valid` = 1: 0xF3 reads 0x01; 0xF4 reads the key; `tty_in_ack` = 1 only when `re` = 1 at address 0xF4.
- [ ] 0xF5–0xFF read 0x00.
