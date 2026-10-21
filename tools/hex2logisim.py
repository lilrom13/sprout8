#!/usr/bin/env python3
"""Convert Sprout-8 .hex program images into Logisim-evolution memory images.

Reads the repository's .hex format (hex bytes, "@xx" sets the address, '#' starts a
comment; the same parser as the emulator) and writes a 256-byte image in Logisim's
"v3.0 hex words addressed" format, ready for right-click -> Load Image on the RAM in
mem_io (module spec, section 10.5).

Usage:
    python3 tools/hex2logisim.py sw/programs/b1_sum_leds.hex          # -> build/logisim/b1_sum_leds.img
    python3 tools/hex2logisim.py sw/programs/*.hex                    # one image per program
    python3 tools/hex2logisim.py prog.hex -o prog.img
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sw" / "emulator"))
from sprout8 import load_hex  # noqa: E402

DEFAULT_OUT = ROOT / "build" / "logisim"
WORDS_PER_LINE = 16
IO_BASE = 0xF0


def to_logisim(mem: bytes, source: str) -> str:
    lines = ["v3.0 hex words addressed", f"# Sprout-8 memory image from {source}"]
    for base in range(0, 256, WORDS_PER_LINE):
        words = " ".join(f"{b:02x}" for b in mem[base:base + WORDS_PER_LINE])
        lines.append(f"{base:02x}: {words}")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", type=Path, help=".hex program image(s)")
    ap.add_argument("-o", "--output", type=Path, help="output file (only with a single input)")
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT,
                    help=f"output directory when -o is not given (default: {DEFAULT_OUT.relative_to(ROOT)})")
    args = ap.parse_args(argv)

    if args.output and len(args.inputs) > 1:
        ap.error("-o can only be used with a single input")

    for src in args.inputs:
        try:
            mem = load_hex(src.read_text())
        except (OSError, ValueError) as e:
            print(f"{src}: {e}", file=sys.stderr)
            return 1
        # mem_io has no RAM behind 0xF0-0xFF (ISA 4.1): bytes placed there are never seen
        if any(mem[IO_BASE:]):
            print(f"{src}: warning: bytes at 0xF0-0xFF land in the I/O range and are ignored",
                  file=sys.stderr)
        dst = args.output or args.out_dir / (src.stem + ".img")
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(to_logisim(mem, src.name))
        print(f"{src} -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
