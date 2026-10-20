#!/usr/bin/env python3
"""Mutation check: does the test suite catch real bugs?

Each mutation plants one small, realistic bug in a copy of hw/, then reruns the
testbenches with tools/run_tests.py --hw-dir. A mutation is "killed" if at
least one testbench fails; a surviving mutation is a gap in the tests.

Writes <out>/mutation.json, which tools/report.py adds to the report.
Exit status is 1 if any mutation survives (or is invalid), so CI can gate on it.

Usage: python3 tools/mutation_check.py [--out build/report] [--only-file alu.vhd]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (description, file under hw/rtl, original text, mutated text, testbenches to run)
MUTATIONS = [
    ("ALU: SUB borrow uses <= instead of <", "alu.vhd",
     "if unsigned(a) < unsigned(b) then", "if unsigned(a) <= unsigned(b) then", "tb_alu tb_cpu"),
    ("ALU: SHR carry taken from bit 7", "alu.vhd",
     "r  := '0' & a(7 downto 1);\n        cy := a(0);", "r  := '0' & a(7 downto 1);\n        cy := a(7);", "tb_alu tb_cpu"),
    ("ALU: Z flag ignores bit 7", "alu.vhd",
     "if r = x\"00\" then", "if r(6 downto 0) = \"0000000\" then", "tb_alu tb_cpu"),
    ("Register file: reset does not clear", "regfile.vhd",
     "regs <= (others => (others => '0'));\n      elsif", "null;\n      elsif", "tb_regfile tb_cpu"),
    ("Register file: port B reads port A's address", "regfile.vhd",
     "rdata_b  <= regs(to_integer(unsigned(raddr_b)));", "rdata_b  <= regs(to_integer(unsigned(raddr_a)));", "tb_regfile tb_cpu"),
    ("Flags: C not loaded", "flags.vhd",
     "zr <= z_in; cr <= c_in; nr <= n_in;", "zr <= z_in; nr <= n_in;", "tb_flags tb_cpu"),
    ("PC: increment has priority over load", "pc.vhd",
     "elsif load = '1' then\n        r <= unsigned(d);\n      elsif inc = '1' then\n        r <= r + 1;",
     "elsif inc = '1' then\n        r <= r + 1;\n      elsif load = '1' then\n        r <= unsigned(d);", "tb_pc tb_cpu"),
    ("SP: resets to 0xEF", "sprout8_pkg.vhd",
     "constant RESET_SP : byte_t := x\"F0\";", "constant RESET_SP : byte_t := x\"EF\";", "tb_sp tb_cpu"),
    ("IR: rd and rs fields swapped", "ir.vhd",
     "rd     <= r0(3 downto 2);\n  rs     <= r0(1 downto 0);", "rd     <= r0(1 downto 0);\n  rs     <= r0(3 downto 2);", "tb_ir tb_cpu"),
    ("Memory: I/O writes alias into RAM", "mem_io.vhd",
     "if not is_io then\n          ram(", "if true then\n          ram(", "tb_mem_io tb_cpu"),
    ("Memory: TTY_IN consumed without the read strobe", "mem_io.vhd",
     "tty_in_ack    <= '1' when re = '1' and", "tty_in_ack    <= '1' when", "tb_mem_io tb_cpu"),
    ("Memory: LEDS port reads back 0x00", "mem_io.vhd",
     "    elsif addr = PORT_LEDS then\n      rdata <= leds_r;", "    elsif addr = PORT_LEDS then\n      rdata <= x\"00\";", "tb_mem_io tb_cpu"),
    ("Control: JNZ tests C instead of Z", "control.vhd",
     "when \"10\"   => take := z = '0';", "when \"10\"   => take := c = '0';", "tb_control tb_cpu"),
    ("Control: INC forgets to force B = 1", "control.vhd",
     "w.alu_op := ALU_ADD; w.alu_b_one := '1';   -- INC", "w.alu_op := ALU_ADD;   -- INC", "tb_control tb_cpu"),
    ("Control: CMP writes its result", "control.vhd",
     "w.alu_op := ALU_SUB; w.flags_load := '1'; w.step_reset := '1';",
     "w.alu_op := ALU_SUB; w.flags_load := '1'; w.step_reset := '1'; w.bus_src := BUS_ALU; w.reg_we := '1';", "tb_control tb_cpu"),
    ("Control: PUSH writes before decrementing SP", "control.vhd",
     "when 4 => w.sp_dec := '1';\n                    when 5 => w.bus_src := BUS_SP; w.mar_load := '1';\n                    when others => w.bus_src := BUS_RD;",
     "when 4 => w.bus_src := BUS_SP; w.mar_load := '1';\n                    when 5 => w.sp_dec := '1';\n                    when others => w.bus_src := BUS_RD;", "tb_control tb_cpu"),
    ("Control: illegal stack encoding treated as NOP", "control.vhd",
     "                when others =>                                -- reserved\n                  w.step_reset := '1'; halt_now <= '1'; ill_now <= '1';\n              end case;\n          end case;",
     "                when others =>                                -- reserved\n                  w.step_reset := '1';\n              end case;\n          end case;", "tb_control tb_cpu"),
    ("Control: halted CPU keeps fetching", "control.vhd",
     "if halted_r = '1' then\n      w := CTRL_IDLE;\n    else", "if false then\n      w := CTRL_IDLE;\n    else", "tb_control tb_cpu"),
]


def run_one(desc: str, fname: str, old: str, new: str, tbs: str, ghdl: str) -> dict:
    rec = {"description": desc, "file": f"hw/rtl/{fname}", "testbenches": tbs.split(),
           "caught_by": [], "result": "invalid"}
    with tempfile.TemporaryDirectory(prefix="s8mut_") as tmp:
        hw = Path(tmp) / "hw"
        shutil.copytree(ROOT / "hw", hw)
        path = hw / "rtl" / fname
        src = path.read_text()
        if src.count(old) != 1:
            rec["detail"] = "pattern not found exactly once (update the mutation)"
            return rec
        path.write_text(src.replace(old, new))
        out = Path(tmp) / "report"
        r = subprocess.run([sys.executable, str(ROOT / "tools" / "run_tests.py"), "--hw-dir", str(hw),
                            "--out", str(out), "--waves", "never", "-q", "--ghdl", ghdl,
                            "--only", *tbs.split()], cwd=ROOT, capture_output=True, text=True,
                           env={k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"})
        if r.returncode == 2:
            rec["detail"] = "mutant does not compile"
            return rec
        res = json.loads((out / "results.json").read_text())
        rec["caught_by"] = [t["name"] for t in res["testbenches"] if t["status"] != "passed"]
        rec["result"] = "killed" if rec["caught_by"] else "survived"
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(ROOT / "build" / "report"))
    ap.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"))
    ap.add_argument("--only-file", help="only mutations in this RTL file, e.g. alu.vhd")
    args = ap.parse_args()

    muts = [m for m in MUTATIONS if not args.only_file or m[1] == args.only_file]
    records = []
    for m in muts:
        rec = run_one(*m, ghdl=args.ghdl)
        records.append(rec)
        tag = {"killed": "KILLED  ", "survived": "SURVIVED"}.get(rec["result"], "INVALID ")
        extra = ", ".join(rec["caught_by"]) or rec.get("detail", "<-- test gap")
        print(f"  {tag} {rec['description']:55s} {extra}", flush=True)
        if rec["result"] != "killed" and os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::warning title=Mutation {rec['result']}::{rec['description']} ({rec['file']})")

    killed = sum(r["result"] == "killed" for r in records)
    data = {"totals": {"total": len(records), "killed": killed,
                       "survived": sum(r["result"] == "survived" for r in records),
                       "invalid": sum(r["result"] == "invalid" for r in records)},
            "mutations": records}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "mutation.json").write_text(json.dumps(data, indent=2))
    print(f"{killed}/{len(records)} mutations killed -> {out / 'mutation.json'}")
    return 0 if killed == len(records) else 1


if __name__ == "__main__":
    sys.exit(main())
