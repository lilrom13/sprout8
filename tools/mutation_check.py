#!/usr/bin/env python3
"""Mutation check: does the test suite catch real bugs in the Logisim design?

Each mutation plants one small, realistic bug in a copy of the Logisim project, then
reruns the circuit's testbench with tools/run_tests.py --hw-dir. A mutation is "killed"
if the testbench fails; a surviving mutation is a gap in the tests.

The mutations are generated from the drawing itself, so they follow the design as it
grows. For every circuit that has a testbench (the first circuit listed for it in
hw/manifest.json), each of these components gives one mutant:

    Constant      value with its lowest bit flipped (0x01 -> 0x00, 0xF0 -> 0xF1)
    Gates         AND <-> OR, NAND <-> NOR, XOR -> OR, XNOR -> NOR
    Adder         -> Subtractor, and Subtractor -> Adder
    Splitter      two bits that go to different outputs swapped (e.g. rd <-> rs)

A mutant that Logisim cannot export (for example when the replacement component has
different pins) is reported as "invalid" and does not count as a test gap.

Writes <out>/mutation.json, which tools/report.py adds to the report.
Exit status is 1 if any mutation survives, so CI can gate on it.

Usage:
    python3 tools/mutation_check.py [--out build/report] [--only-circuit pc] [--list]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "hw" / "manifest.json"

GATE_SWAP = {"AND Gate": "OR Gate", "OR Gate": "AND Gate", "NAND Gate": "NOR Gate",
             "NOR Gate": "NAND Gate", "XOR Gate": "OR Gate", "XNOR Gate": "NOR Gate"}
ARITH_SWAP = {"Adder": "Subtractor", "Subtractor": "Adder"}
# shorter runs of the long testbenches: a planted bug shows up within a few random programs
MUTANT_GENERICS = {"tb_cpu": {"N_RANDOM": 30}}


def attrs(comp: ET.Element) -> dict[str, ET.Element]:
    return {a.get("name"): a for a in comp.findall("a")}


def set_attr(comp: ET.Element, name: str, val: str) -> None:
    a = attrs(comp).get(name)
    if a is None:
        a = ET.SubElement(comp, "a", name=name)
    a.set("val", val)


def mutants_of(comp: ET.Element) -> list[tuple[str, callable]]:
    """(description, function that applies the mutation to this component) pairs."""
    kind, a = comp.get("name"), attrs(comp)
    out = []
    if kind == "Constant":
        width = int(a["width"].get("val")) if "width" in a else 1
        value = int(a["value"].get("val"), 0) if "value" in a else 1          # Logisim's default is 1
        new = value ^ 1
        digits = max(1, (width + 3) // 4)
        out.append((f"Constant 0x{value:0{digits}x} -> 0x{new:0{digits}x}",
                    lambda c, n=new: set_attr(c, "value", hex(n))))
    elif kind in GATE_SWAP:
        out.append((f"{kind} -> {GATE_SWAP[kind]}", lambda c, k=GATE_SWAP[kind]: c.set("name", k)))
    elif kind in ARITH_SWAP:
        out.append((f"{kind} -> {ARITH_SWAP[kind]}", lambda c, k=ARITH_SWAP[kind]: c.set("name", k)))
    elif kind == "Splitter":
        bits = {int(n[3:]): e.get("val") for n, e in a.items() if n.startswith("bit") and n[3:].isdigit()}
        mapped = sorted((b, v) for b, v in bits.items() if v != "none")
        if mapped and len({v for _, v in mapped}) > 1:
            (lo, vlo), (hi, vhi) = mapped[0], mapped[-1]      # bits from the first and last groups
            def swap(c, lo=lo, hi=hi, vlo=vlo, vhi=vhi):
                set_attr(c, f"bit{lo}", vhi)
                set_attr(c, f"bit{hi}", vlo)
            out.append((f"Splitter bits {lo} and {hi} swapped", swap))
    return out


def plan(manifest: dict, circ: Path, only: str | None) -> list[dict]:
    """Every mutant of every tested circuit, without applying any."""
    tree = ET.parse(circ)
    present = {c.get("name"): c for c in tree.getroot().findall("circuit")}
    jobs = []
    for tb in manifest["testbenches"]:
        circuit = tb["circuits"][0]                       # a circuit is mutated for its own testbench
        if circuit not in present or any(c not in present for c in tb["circuits"]):
            continue
        if only and circuit != only:
            continue
        for idx, comp in enumerate(present[circuit].findall("comp")):
            for desc, _ in mutants_of(comp):
                jobs.append({"circuit": circuit, "comp_index": idx, "loc": comp.get("loc"),
                             "description": f"{circuit}: {desc} at {comp.get('loc')}",
                             "testbench": tb["name"], "mutation": desc})
    return jobs


def apply(circ_src: Path, circ_dst: Path, job: dict) -> None:
    tree = ET.parse(circ_src)
    circuit = next(c for c in tree.getroot().findall("circuit") if c.get("name") == job["circuit"])
    comp = circuit.findall("comp")[job["comp_index"]]
    fn = next(f for d, f in mutants_of(comp) if d == job["mutation"])
    fn(comp)
    tree.write(circ_dst, xml_declaration=True, encoding="UTF-8")


def run_one(job: dict, manifest: dict, ghdl: str, logisim: str | None) -> dict:
    rec = {"description": job["description"], "file": f"{manifest['design']['logisim']}#{job['circuit']}",
           "testbenches": [job["testbench"]], "caught_by": [], "result": "invalid"}
    with tempfile.TemporaryDirectory(prefix="s8mut_") as tmp:
        hw = Path(tmp) / "hw"
        shutil.copytree(ROOT / "hw", hw)
        circ = hw / Path(manifest["design"]["logisim"]).relative_to("hw")
        apply(circ, circ, job)
        out = Path(tmp) / "report"
        cmd = [sys.executable, str(ROOT / "tools" / "run_tests.py"), "--hw-dir", str(hw), "--out", str(out),
               "--waves", "never", "-q", "--ghdl", ghdl, "--only", job["testbench"], "-j", "1"]
        cmd += [f"-g{job['testbench']}.{k}={v}" for k, v in MUTANT_GENERICS.get(job["testbench"], {}).items()]
        if logisim:
            cmd += ["--logisim", logisim]
        subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                       env={k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"})
        if not (out / "results.json").exists():
            rec["detail"] = "test runner did not produce results"
            return rec
        tb = json.loads((out / "results.json").read_text())["testbenches"][0]
        if "not run: the design did not build" in tb["notes"]:
            rec["detail"] = "mutant does not export or compile"
            return rec
        rec["caught_by"] = [tb["name"]] if tb["status"] != "passed" else []
        rec["result"] = "killed" if rec["caught_by"] else "survived"
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(ROOT / "build" / "report"))
    ap.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"))
    ap.add_argument("--logisim", help="Logisim-evolution launcher or release .jar (default: $LOGISIM, PATH, /opt)")
    ap.add_argument("--only-circuit", help="only mutate this circuit, e.g. pc")
    ap.add_argument("--list", action="store_true", help="list the mutations without running them")
    ap.add_argument("-j", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    jobs = plan(manifest, ROOT / manifest["design"]["logisim"], args.only_circuit)
    if args.list:
        for j in jobs:
            print(f"  {j['description']:60s} {j['testbench']}")
        print(f"{len(jobs)} mutations")
        return 0

    records = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(run_one, j, manifest, args.ghdl, args.logisim) for j in jobs]
        for fut in futs:                                   # in plan order, for a stable report
            rec = fut.result()
            records.append(rec)
            tag = {"killed": "KILLED  ", "survived": "SURVIVED"}.get(rec["result"], "INVALID ")
            extra = ", ".join(rec["caught_by"]) or rec.get("detail", "<-- test gap")
            print(f"  {tag} {rec['description']:60s} {extra}", flush=True)
            if rec["result"] == "survived" and os.environ.get("GITHUB_ACTIONS") == "true":
                print(f"::warning title=Mutation survived::{rec['description']} ({rec['file']})")

    killed = sum(r["result"] == "killed" for r in records)
    survived = sum(r["result"] == "survived" for r in records)
    data = {"totals": {"total": len(records), "killed": killed, "survived": survived,
                       "invalid": sum(r["result"] == "invalid" for r in records)},
            "mutations": records}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "mutation.json").write_text(json.dumps(data, indent=2))
    print(f"{killed}/{len(records)} mutations killed, {survived} survived -> {out / 'mutation.json'}")
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
