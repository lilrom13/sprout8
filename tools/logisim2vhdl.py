#!/usr/bin/env python3
"""Export a circuit of the Logisim project to VHDL, and optionally run its testbench.

Uses Logisim-evolution's own HDL generator (the FPGA flow in "HDL only" mode), so the
VHDL is a structural copy of the drawing: every Register, Adder, gate... becomes a
component instance. The generated entity has the circuit's name and one port per pin,
named after the pin label, which is what the testbenches in hw/tb/ instantiate.

    python3 tools/logisim2vhdl.py pc            # -> build/logisim/vhdl/pc/
    python3 tools/logisim2vhdl.py pc --test     # export, then run hw/tb/tb_pc.vhd on it with GHDL
    make logisim-tb TB=tb_pc                    # the same

How the export is made to run headless (see hw/logisim/NOTES.md):
  * Logisim refuses to generate HDL until every pin of the circuit is mapped to the
    FPGA board. A copy of the project gets a board map that ties every input to a
    constant 0 and leaves every output open. This only affects Logisim's board wrapper
    (logisimTopLevelShell), which is not used; the circuit's own entity is unchanged.
  * Logisim writes into its FPGA workspace (by default ~/logisim_evolution_workspace)
    and keeps preferences in ~/.java. Both are redirected to a temporary directory by
    giving the JVM a temporary user.home, so nothing outside build/ is touched.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CIRC = ROOT / "hw" / "logisim" / "sprout8.circ"
OUT = ROOT / "build" / "logisim" / "vhdl"
BOARD = "BASYS3"                     # any board shipped with Logisim works: nothing is mapped to it
DEFAULT_LOGISIM = "/opt/logisim-evolution/bin/logisim-evolution"


def find_logisim(given: str | None) -> str:
    for cand in (given, os.environ.get("LOGISIM"), shutil.which("logisim-evolution"), DEFAULT_LOGISIM):
        if cand and Path(cand).exists():
            return cand
    sys.exit("error: Logisim-evolution not found. Pass --logisim /path/to/logisim-evolution or set $LOGISIM")


def add_board_map(circ: Path, circuit: str, board: str) -> None:
    """Map every pin of `circuit`: inputs to constant 0, outputs left open."""
    tree = ET.parse(circ)
    matches = [c for c in tree.getroot().findall("circuit") if c.get("name") == circuit]
    if not matches:
        names = [c.get("name") for c in tree.getroot().findall("circuit")]
        sys.exit(f"error: no circuit named {circuit!r} in {CIRC.name} (circuits: {', '.join(names)})")
    circ_elt = matches[0]
    for old in circ_elt.findall("boardmap"):
        circ_elt.remove(old)
    bmap = ET.SubElement(circ_elt, "boardmap", boardname=board)
    for comp in circ_elt.findall("comp"):
        if comp.get("name") != "Pin":
            continue
        attrs = {a.get("name"): a.get("val") for a in comp.findall("a")}
        label = attrs.get("label")
        if not label:
            sys.exit(f"error: circuit {circuit!r} has a pin without a label; label every pin")
        if attrs.get("type") == "output":
            ET.SubElement(bmap, "mc", key="/" + label, open="open")
        else:
            ET.SubElement(bmap, "mc", key="/" + label, vconst="0")
    tree.write(circ, xml_declaration=True, encoding="UTF-8")


def export(circuit: str, circ: Path, out_root: Path, logisim: str) -> Path:
    """Generate the VHDL of `circuit` into out_root/<circuit>/ and return that directory."""
    with tempfile.TemporaryDirectory(prefix="logisim2vhdl-") as tmp:
        tmp = Path(tmp)
        work_circ = tmp / circ.name
        shutil.copy(circ, work_circ)
        add_board_map(work_circ, circuit, BOARD)

        env = dict(os.environ, JAVA_TOOL_OPTIONS=f"-Duser.home={tmp} -Djava.awt.headless=true")
        r = subprocess.run([logisim, "--test-fpga", str(work_circ), circuit, BOARD, "HDLONLY"],
                           cwd=tmp, env=env, capture_output=True, text=True, timeout=300)
        log = r.stdout + r.stderr
        found = list(tmp.glob(f"logisim_evolution_workspace/*/{circuit}/vhdl"))
        if not found:
            sys.exit(f"error: Logisim did not generate VHDL for {circuit!r}:\n"
                     + "\n".join(ln for ln in log.splitlines() if "ERROR" in ln or "WARN" in ln)
                     or log[-3000:])
        for ln in log.splitlines():
            if "WARN" in ln:
                print("logisim: " + ln.split(" - ", 1)[-1])

        dest = out_root / circuit
        shutil.rmtree(dest, ignore_errors=True)
        for f in found[0].rglob("*.vhd"):
            if f.parent.name == "toplevel":          # Logisim's board wrapper, not part of the design
                continue
            target = dest / f.relative_to(found[0])
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(f, target)
    return dest


def run_testbench(circuit: str, vhdl_dir: Path, ghdl: str) -> int:
    manifest = json.loads((ROOT / "hw" / "manifest.json").read_text())
    tb_name = f"tb_{circuit}"
    tb = next((t for t in manifest["testbenches"] if t["name"] == tb_name), None)
    if tb is None:
        sys.exit(f"error: no testbench {tb_name} in hw/manifest.json")
    if shutil.which(ghdl) is None and not Path(ghdl).exists():
        sys.exit(f"error: '{ghdl}' not found. Install GHDL or pass --ghdl /path/to/ghdl")

    std = manifest.get("vhdl_std", "08")
    work = OUT.parent / "ghdl-work" / tb_name
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    # architectures need their entity first; the generated components are bound at elaboration
    generated = sorted(vhdl_dir.rglob("*_entity.vhd")) + sorted(vhdl_dir.rglob("*_behavior.vhd"))
    sources = ([ROOT / "hw" / "rtl" / "sprout8_pkg.vhd"] + [ROOT / f for f in manifest["tb_support"]]
               + generated + [ROOT / tb["file"]])
    common = [f"--std={std}", f"--workdir={work}"]
    for src in sources:
        r = subprocess.run([ghdl, "-a", *common, str(src)], capture_output=True, text=True)
        if r.returncode:
            print(r.stdout + r.stderr, file=sys.stderr)
            print(f"{tb_name}: FAIL (compile error in {src.relative_to(ROOT)})")
            return 1

    generics = [f"-g{k}={v}" for k, v in tb.get("generics", {}).items()]
    try:
        r = subprocess.run([ghdl, "--elab-run", *common, tb_name, "--ieee-asserts=disable-at-0", *generics],
                           cwd=ROOT, capture_output=True, text=True, timeout=tb.get("timeout_s", 600))
    except subprocess.TimeoutExpired:
        print(f"{tb_name}: FAIL (timeout after {tb.get('timeout_s')} s)")
        return 1
    print((r.stdout + r.stderr).rstrip())
    return r.returncode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("circuit", help="circuit name in the Logisim project (e.g. pc)")
    ap.add_argument("--test", action="store_true", help="also run hw/tb/tb_<circuit>.vhd on the export")
    ap.add_argument("--circ", type=Path, default=CIRC, help="Logisim project (default: hw/logisim/sprout8.circ)")
    ap.add_argument("--logisim", help="Logisim-evolution launcher (default: $LOGISIM, PATH, or /opt)")
    ap.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"), help="GHDL executable (default: $GHDL or ghdl)")
    args = ap.parse_args(argv)

    dest = export(args.circuit, args.circ, OUT, find_logisim(args.logisim))
    print(f"{args.circuit}: VHDL in {dest.relative_to(ROOT)}")
    return run_testbench(args.circuit, dest, args.ghdl) if args.test else 0


if __name__ == "__main__":
    sys.exit(main())
