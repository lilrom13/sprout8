#!/usr/bin/env python3
"""Export circuits of the Logisim project to VHDL.

The Sprout-8 design is the Logisim-evolution project hw/logisim/sprout8.circ. This tool
turns one of its circuits into VHDL with Logisim's own HDL generator (the FPGA flow in
"HDL only" mode), so the VHDL is a structural copy of the drawing: every Register, Adder,
gate... becomes a component instance. The generated entity has the circuit's name and
one port per pin, named after the pin label, which is what the testbenches in hw/tb/
instantiate. tools/run_tests.py uses it to test the design; run it by hand to read the
generated VHDL:

    python3 tools/logisim2vhdl.py pc                 # -> build/logisim/vhdl/pc/
    python3 tools/logisim2vhdl.py --list             # circuits in the project

How the export is made to run headless (see hw/logisim/NOTES.md):
  * Logisim refuses to generate HDL until every pin of the circuit is mapped to the
    FPGA board. A copy of the project gets a board map that ties every input to a
    constant 0 and leaves every output open. This only affects Logisim's board wrapper
    (logisimTopLevelShell), which is discarded; the circuit's own entity is unchanged.
  * Logisim writes into its FPGA workspace (by default ~/logisim_evolution_workspace)
    and keeps preferences in ~/.java. Both are redirected to a temporary directory by
    giving the JVM a temporary user.home, so nothing outside the output is touched.

Logisim is found from --logisim, $LOGISIM, `logisim-evolution` on PATH, or
/opt/logisim-evolution. Any of them may be a launcher or the release .jar (run with java).
"""
from __future__ import annotations

import argparse
import os
import re
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


class ExportError(Exception):
    pass


def logisim_command(given: str | None = None) -> list[str]:
    """The command that starts Logisim-evolution, as a list."""
    for cand in (given, os.environ.get("LOGISIM"), shutil.which("logisim-evolution"), DEFAULT_LOGISIM):
        if cand and Path(cand).exists():
            return ["java", "-jar", cand] if cand.endswith(".jar") else [cand]
    raise ExportError("Logisim-evolution not found: pass --logisim /path/to/logisim-evolution "
                      "(or the release .jar), or set $LOGISIM")


def circuits(circ: Path) -> list[str]:
    """Names of the circuits in a Logisim project."""
    return [c.get("name") for c in ET.parse(circ).getroot().findall("circuit")]


def add_board_map(circ: Path, circuit: str, board: str) -> None:
    """Map every pin of `circuit`: inputs to constant 0, outputs left open."""
    tree = ET.parse(circ)
    matches = [c for c in tree.getroot().findall("circuit") if c.get("name") == circuit]
    if not matches:
        raise ExportError(f"no circuit named {circuit!r} in {circ.name}")
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
            raise ExportError(f"circuit {circuit!r} has a pin without a label; label every pin")
        if attrs.get("type") == "output":
            ET.SubElement(bmap, "mc", key="/" + label, open="open")
        else:
            ET.SubElement(bmap, "mc", key="/" + label, vconst="0")
    tree.write(circ, xml_declaration=True, encoding="UTF-8")


def rename_entity(vhdl_dir: Path, old: str, new: str) -> None:
    """Rename the circuit's own entity, so an adapter can take its name."""
    for f in (vhdl_dir / "circuit" / f"{old}_entity.vhd", vhdl_dir / "circuit" / f"{old}_behavior.vhd"):
        text = f.read_text()
        text = re.sub(rf"\b(ENTITY|END ENTITY|OF)\s+{re.escape(old)}\b", rf"\1 {new}", text, flags=re.I)
        f.write_text(text)


def export(circuit: str, circ: Path, dest: Path, logisim: list[str], rename_to: str | None = None) -> list[str]:
    """Generate the VHDL of `circuit` into `dest`. Returns Logisim's warnings."""
    with tempfile.TemporaryDirectory(prefix="logisim2vhdl-") as tmp:
        tmp = Path(tmp)
        work_circ = tmp / circ.name
        shutil.copy(circ, work_circ)
        add_board_map(work_circ, circuit, BOARD)

        env = dict(os.environ, JAVA_TOOL_OPTIONS=f"-Duser.home={tmp} -Djava.awt.headless=true")
        try:
            r = subprocess.run([*logisim, "--test-fpga", str(work_circ), circuit, BOARD, "HDLONLY"],
                               cwd=tmp, env=env, capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            raise ExportError(f"Logisim timed out exporting {circuit!r}") from None
        log = r.stdout + r.stderr
        found = list(tmp.glob(f"logisim_evolution_workspace/*/{circuit}/vhdl"))
        if not found:
            errors = [ln.split(" - ", 1)[-1] for ln in log.splitlines() if "ERROR" in ln]
            raise ExportError(f"Logisim did not generate VHDL for {circuit!r}: "
                              + ("; ".join(errors) or log[-2000:]))

        shutil.rmtree(dest, ignore_errors=True)
        for f in found[0].rglob("*.vhd"):
            if f.parent.name == "toplevel":          # Logisim's board wrapper, not part of the design
                continue
            target = dest / f.relative_to(found[0])
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(f, target)
    if rename_to:
        rename_entity(dest, circuit, rename_to)
    return [ln.split(" - ", 1)[-1] for ln in log.splitlines() if "WARN" in ln]


def vhdl_files(vhdl_dir: Path) -> list[Path]:
    """Generated files in analysis order: every entity before any architecture."""
    return sorted(vhdl_dir.rglob("*_entity.vhd")) + sorted(vhdl_dir.rglob("*_behavior.vhd"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("circuit", nargs="?", help="circuit name in the Logisim project (e.g. pc)")
    ap.add_argument("--list", action="store_true", help="list the circuits in the project")
    ap.add_argument("--circ", type=Path, default=CIRC, help="Logisim project (default: hw/logisim/sprout8.circ)")
    ap.add_argument("--out-dir", type=Path, default=OUT, help="output directory (default: build/logisim/vhdl)")
    ap.add_argument("--logisim", help="Logisim-evolution launcher or .jar")
    args = ap.parse_args(argv)

    if args.list:
        print("\n".join(circuits(args.circ)))
        return 0
    if not args.circuit:
        ap.error("give a circuit name, or --list")
    try:
        dest = args.out_dir / args.circuit
        for w in export(args.circuit, args.circ, dest, logisim_command(args.logisim)):
            print("logisim: " + w)
    except ExportError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"{args.circuit}: VHDL in {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
