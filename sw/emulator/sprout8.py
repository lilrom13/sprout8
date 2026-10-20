#!/usr/bin/env python3
"""Sprout-8 instruction-set emulator (ISA manual v1.0, chapters 3-6).

Runs a program image in the same .hex format the VHDL memory loads
(hex bytes, "@xx" sets the address, '#' starts a comment).

Usage:
    python3 sw/emulator/sprout8.py sw/programs/b2_print_string.hex
    python3 sw/emulator/sprout8.py sw/programs/b3_echo.hex --keys "hello" --max-instr 200
    python3 sw/emulator/sprout8.py prog.hex --trace
"""
from __future__ import annotations

import argparse
import sys

# reference-implementation cycle counts (ISA manual, chapter 7)
CYCLES = {0x0: 5, 0x1: 5, 0x2: 6, 0x3: 6, 0x4: 6, 0x5: 6, 0x6: 5, 0x7: 5,
          0x8: 5, 0x9: 5, 0xA: 5, 0xB: 5, 0xC: 5, 0xD: 5, 0xE: 5}
REG = "ABCD"


def load_hex(text: str) -> bytearray:
    """Parse the .hex image format into a 256-byte memory image."""
    mem = bytearray(256)
    addr = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        for tok in line.split("#", 1)[0].split():
            try:
                if tok.startswith("@"):
                    addr = int(tok[1:], 16) & 0xFF
                else:                        # "3C", or several bytes run together: "1000"
                    if len(tok) % 2:
                        raise ValueError
                    for i in range(0, len(tok), 2):
                        mem[addr] = int(tok[i:i + 2], 16)
                        addr = (addr + 1) & 0xFF
            except ValueError:
                raise ValueError(f"line {lineno}: bad token {tok!r}") from None
    return mem


class Sprout8:
    def __init__(self, image: bytes | bytearray = b"", keys: str = "", switches: int = 0):
        self.mem = bytearray(256)
        self.mem[:len(image)] = image
        for a in range(0xF0, 0x100):        # no RAM behind the I/O range
            self.mem[a] = 0
        self.r = [0, 0, 0, 0]
        self.pc, self.sp = 0x00, 0xF0
        self.z = self.c = self.n = 0
        self.halted = self.illegal = False
        self.cycles = self.instructions = 0
        self.leds = 0
        self.switches = switches & 0xFF
        self.keys = [ord(k) & 0xFF for k in keys]
        self.tty: list[str] = []

    # ---------------- memory and I/O (chapter 4) ----------------
    def read(self, a: int, side_effects: bool = True) -> int:
        a &= 0xFF
        if a < 0xF0:
            return self.mem[a]
        if a == 0xF0:
            return self.leds
        if a == 0xF1:
            return self.switches
        if a == 0xF3:
            return 1 if self.keys else 0
        if a == 0xF4:
            if not self.keys:
                return 0
            return self.keys.pop(0) if side_effects else self.keys[0]
        return 0

    def write(self, a: int, v: int) -> None:
        a &= 0xFF
        if a < 0xF0:
            self.mem[a] = v
        elif a == 0xF0:
            self.leds = v
        elif a == 0xF2:
            self.tty.append(chr(v))

    def _zn(self, v: int) -> None:
        self.z = int(v & 0xFF == 0)
        self.n = (v >> 7) & 1

    # ---------------- one instruction (chapter 6) ----------------
    def step(self) -> None:
        if self.halted:
            return
        b0 = self.read(self.pc)
        b1 = self.read(self.pc + 1)
        self.pc = (self.pc + 2) & 0xFF
        op, d, s = b0 >> 4, (b0 >> 2) & 3, b0 & 3
        R = self.r
        cyc = CYCLES.get(op, 0)
        if op == 0x0:
            if s == 1:
                self.halted = True
            elif s == 2:
                self.pc = self.read(self.sp); self.sp = (self.sp + 1) & 0xFF; cyc = 7
            elif s == 3:
                self.halted = self.illegal = True
        elif op == 0x1: R[d] = b1
        elif op == 0x2: R[d] = self.read(b1)
        elif op == 0x3: self.write(b1, R[d])
        elif op == 0x4: R[d] = self.read(R[s])
        elif op == 0x5: self.write(R[s], R[d])
        elif op == 0x6: R[d] = R[s]
        elif op == 0x7:
            t = R[d] + R[s]; R[d] = t & 0xFF; self.c = int(t > 255); self._zn(R[d])
        elif op in (0x8, 0xC):
            t = (R[d] - R[s]) & 0xFF; self.c = int(R[d] < R[s]); self._zn(t)
            if op == 0x8:
                R[d] = t
        elif op in (0x9, 0xA, 0xB):
            t = R[d] & R[s] if op == 0x9 else R[d] | R[s] if op == 0xA else R[d] ^ R[s]
            R[d] = t; self.c = 0; self._zn(t)
        elif op == 0xD:
            v = R[d]
            if s == 0:   t, c = (v + 1) & 0xFF, int(v == 0xFF)
            elif s == 1: t, c = (v - 1) & 0xFF, int(v == 0x00)
            elif s == 2: t, c = (v << 1) & 0xFF, v >> 7
            else:        t, c = v >> 1, v & 1
            R[d] = t; self.c = c; self._zn(t)
        elif op == 0xE:
            if (True, self.z == 1, self.z == 0, self.c == 1)[d]:
                self.pc = b1
        else:  # 0xF stack group
            if s == 0:
                self.sp = (self.sp - 1) & 0xFF; self.write(self.sp, R[d]); cyc = 7
            elif s == 1:
                R[d] = self.read(self.sp); self.sp = (self.sp + 1) & 0xFF; cyc = 7
            elif s == 2:
                self.sp = (self.sp - 1) & 0xFF; self.write(self.sp, self.pc); self.pc = b1; cyc = 8
            else:
                self.halted = self.illegal = True
        self.cycles += cyc
        self.instructions += 1

    def run(self, max_instr: int = 100_000, trace=None) -> "Sprout8":
        while not self.halted and self.instructions < max_instr:
            pc = self.pc
            self.step()
            if trace:
                trace(pc, self)
        return self

    def state(self) -> str:
        regs = " ".join(f"{REG[i]}={v:02X}" for i, v in enumerate(self.r))
        return (f"PC={self.pc:02X} SP={self.sp:02X} {regs} Z={self.z} C={self.c} N={self.n} "
                f"LEDS={self.leds:02X}{' HALTED' if self.halted else ''}{' ILLEGAL' if self.illegal else ''}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help=".hex program image")
    ap.add_argument("--keys", default="", help="keys queued on the TTY input")
    ap.add_argument("--switches", type=lambda x: int(x, 0), default=0)
    ap.add_argument("--max-instr", type=int, default=100_000)
    ap.add_argument("--trace", action="store_true", help="print the state after every instruction")
    args = ap.parse_args(argv)
    with open(args.image) as f:
        cpu = Sprout8(load_hex(f.read()), keys=args.keys, switches=args.switches)
    tracer = (lambda pc, m: print(f"{pc:02X}: {m.state()}")) if args.trace else None
    cpu.run(args.max_instr, tracer)
    print(cpu.state())
    print(f"{cpu.instructions} instructions, {cpu.cycles} cycles")
    if cpu.tty:
        print("terminal: " + "".join(cpu.tty))
    return 1 if cpu.illegal else 0


if __name__ == "__main__":
    sys.exit(main())
