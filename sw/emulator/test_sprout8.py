"""Unit tests for the Python emulator. Run: python3 -m unittest discover -s sw/emulator -v"""
import unittest
from pathlib import Path

from sprout8 import Sprout8, load_hex

PROGRAMS = Path(__file__).resolve().parent.parent / "programs"


def prog(name: str, **kw) -> Sprout8:
    return Sprout8(load_hex((PROGRAMS / name).read_text()), **kw)


def hexprog(text: str, **kw) -> Sprout8:
    return Sprout8(load_hex(text), **kw)


class AppendixB(unittest.TestCase):
    def test_b1_sum_to_leds(self):
        m = prog("b1_sum_leds.hex").run()
        self.assertEqual(m.leds, 0x0F)
        self.assertEqual(m.cycles, 96)

    def test_b2_print_string(self):
        m = prog("b2_print_string.hex").run()
        self.assertEqual("".join(m.tty), "HI!")
        self.assertEqual(m.cycles, 172)
        self.assertEqual(m.sp, 0xF0)

    def test_b3_echo(self):
        m = prog("b3_echo.hex", keys="ok!").run(max_instr=200)
        self.assertEqual("".join(m.tty), "ok!")
        self.assertFalse(m.halted)


class AppendixC(unittest.TestCase):
    def test_c2_add_carry(self):
        m = hexprog("10FF 1401 7100 0100").run()
        self.assertEqual((m.r[0], m.z, m.c, m.n), (0, 1, 1, 0))

    def test_c3_borrow(self):
        m = hexprog("1003 1405 C100 0100").run()
        self.assertEqual((m.r[0], m.z, m.c, m.n), (3, 0, 1, 1))

    def test_c7_pc_wrap(self):
        m = hexprog("E0FE")
        m.step(); m.step()
        self.assertEqual(m.pc, 0x00)

    def test_c8_sp_wrap(self):
        m = hexprog("F100 " * 16 + "F000 0100").run()
        self.assertEqual(m.sp, 0xFF)

    def test_c10_call_ret(self):
        m = hexprog("E010 @10 F214 0100 0200").run()
        self.assertEqual(m.mem[0xEF], 0x12)
        self.assertEqual(m.sp, 0xF0)

    def test_c13_illegal(self):
        m = hexprog("1005 FF00 1007").run()
        self.assertTrue(m.halted and m.illegal)
        self.assertEqual((m.r[0], m.pc), (5, 0x04))

    def test_c16_tty_in_consumed(self):
        m = hexprog("20F4 24F4 0100", keys="k").run()
        self.assertEqual((m.r[0], m.r[1]), (0x6B, 0x00))


class Loader(unittest.TestCase):
    def test_format(self):
        mem = load_hex("# comment\n10 2a  # two\n@40\nBE\n")
        self.assertEqual((mem[0], mem[1], mem[0x40]), (0x10, 0x2A, 0xBE))

    def test_bad_token(self):
        with self.assertRaises(ValueError):
            load_hex("1G")


if __name__ == "__main__":
    unittest.main()
