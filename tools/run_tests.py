#!/usr/bin/env python3
"""Sprout-8 test runner.

Compiles the RTL and testbenches listed in hw/manifest.json with GHDL, runs the
testbenches in parallel and writes machine-readable results:

    <out>/results.json   full results (input for tools/report.py)
    <out>/junit.xml      JUnit XML for CI test reporters
    <out>/logs/<tb>.log  simulator output per testbench
    <out>/waves/<tb>.ghw waveform of each failing testbench (--waves on-failure)

Exit status: 0 if every testbench passed, 1 if any failed, 2 on a compile error.

Examples:
    python3 tools/run_tests.py
    python3 tools/run_tests.py --only tb_alu tb_cpu
    python3 tools/run_tests.py --profile nightly -g tb_cpu.RAND_SEED=1234
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

RE_PASS = re.compile(r"(\w+): PASS \((\d+) checks\)")
RE_FAIL = re.compile(r"(\w+): FAIL \((\d+) of (\d+) checks failed\)")
RE_CHECK = re.compile(r"CHECK FAILED: (.*)")
RE_NOTE = re.compile(r"\(report note\):\s*(.*)")
RE_SIMEND = re.compile(r"simulation (?:finished|stopped) @(\S+)")
IN_GHA = os.environ.get("GITHUB_ACTIONS") == "true"


# --------------------------------------------------------------------------- helpers
def sh(cmd: list[str], timeout: float | None = None, cwd: Path = ROOT) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def ghdl_info(ghdl: str) -> dict:
    try:
        out = sh([ghdl, "--version"]).stdout
    except FileNotFoundError:
        sys.exit(f"error: '{ghdl}' not found. Install GHDL or pass --ghdl /path/to/ghdl")
    first = out.splitlines()[0] if out else "unknown"
    backend = "mcode" if "mcode" in out else ("llvm" if "llvm" in out.lower() else "gcc" if "GCC" in out else "unknown")
    return {"version": first.strip(), "backend": backend}


def remap(path: str, hw_dir: Path | None) -> Path:
    """Paths in the manifest start with 'hw/'. --hw-dir points them at another tree (used by mutation tests)."""
    if hw_dir is not None and path.startswith("hw/"):
        return hw_dir / path[3:]
    return ROOT / path


def parse_generic_overrides(items: list[str]) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    for item in items:
        m = re.fullmatch(r"(\w+)\.(\w+)=(.*)", item)
        if not m:
            sys.exit(f"error: bad -g value '{item}', expected tb_name.GENERIC=value")
        out.setdefault(m[1], {})[m[2]] = m[3]
    return out


def annotate(level: str, title: str, msg: str) -> None:
    if IN_GHA:
        msg = msg.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::{level} title={title}::{msg}")


# --------------------------------------------------------------------------- compile
def compile_all(ghdl: str, manifest: dict, work: Path, hw_dir: Path | None, std: str) -> tuple[bool, str]:
    work.mkdir(parents=True, exist_ok=True)
    files = manifest["rtl"] + manifest["tb_support"] + [t["file"] for t in manifest["testbenches"]]
    log = []
    for f in files:
        r = sh([ghdl, "-a", f"--std={std}", f"--workdir={work}", str(remap(f, hw_dir))])
        if r.returncode != 0:
            log.append(f"--- {f}\n{r.stdout}{r.stderr}")
            return False, "\n".join(log)
    return True, ""


# --------------------------------------------------------------------------- run one
def parse_log(text: str) -> dict:
    res = {"status": "error", "checks": 0, "failed_checks": 0, "failures": [], "notes": [], "sim_time": None}
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if m := RE_PASS.search(line):
            res.update(status="passed", checks=int(m[2]))
        elif m := RE_FAIL.search(line):
            res.update(status="failed", failed_checks=int(m[2]), checks=int(m[3]))
        elif m := RE_CHECK.search(line):
            msg = m[1]
            j = i + 1
            while j < len(lines) and lines[j].startswith("      "):   # continuation lines
                msg += "\n" + lines[j].strip()
                j += 1
            res["failures"].append(msg)
        elif m := RE_NOTE.search(line):
            note = m[1].strip()
            if not RE_PASS.search(note) and note:
                res["notes"].append(note)
        if m := RE_SIMEND.search(line):
            res["sim_time"] = m[1]
    if res["status"] == "error" and res["failures"]:
        res["status"] = "failed"
    return res


def run_tb(ghdl: str, backend: str, tb: dict, work: Path, generics: dict, std: str,
           out: Path, wave: bool = False) -> dict:
    name = tb["name"]
    gargs = [f"-g{k}={v}" for k, v in generics.items()]
    run_opts = ["--ieee-asserts=disable-at-0"] + gargs
    if wave:
        (out / "waves").mkdir(parents=True, exist_ok=True)
        run_opts.append(f"--wave={out / 'waves' / (name + '.ghw')}")
    timeout = tb.get("timeout_s", 600)
    t0 = time.monotonic()
    try:
        if backend == "mcode":
            r = sh([ghdl, "--elab-run", f"--std={std}", f"--workdir={work}", name] + run_opts, timeout=timeout)
        else:  # llvm / gcc produce an executable; keep each one separate so runs can be parallel
            exe = work / f"{name}.exe"
            e = sh([ghdl, "-e", f"--std={std}", f"--workdir={work}", "-o", str(exe), name])
            if e.returncode != 0:
                r = e
            else:
                r = sh([str(exe)] + run_opts, timeout=timeout)
        text = r.stdout + r.stderr
        res = parse_log(text)
        if r.returncode != 0 and res["status"] == "passed":
            res["status"] = "error"          # PASS printed but the simulator still failed
        if r.returncode == 0 and res["status"] == "error":
            res["notes"].append("simulation ended without a PASS/FAIL summary")
    except subprocess.TimeoutExpired as exc:
        text = (exc.stdout or "") + (exc.stderr or "") if isinstance(exc.stdout, str) else ""
        res = parse_log(text)
        res["status"] = "timeout"
        res["failures"].append(f"timed out after {timeout} s")
    res["duration_s"] = round(time.monotonic() - t0, 2)
    (out / "logs").mkdir(parents=True, exist_ok=True)
    log_name = f"{name}{'.wave' if wave else ''}.log"
    (out / "logs" / log_name).write_text(text)
    res.update(name=name, unit=tb.get("unit", name), file=tb["file"], generics=generics,
               log=f"logs/{log_name}")
    return res


# --------------------------------------------------------------------------- outputs
def write_junit(results: dict, path: Path) -> None:
    tbs = results["testbenches"]
    suite = ET.Element("testsuite", name="sprout8", tests=str(len(tbs)),
                       failures=str(sum(t["status"] == "failed" for t in tbs)),
                       errors=str(sum(t["status"] in ("error", "timeout") for t in tbs)),
                       time=str(sum(t["duration_s"] for t in tbs)),
                       timestamp=results["meta"]["started"])
    props = ET.SubElement(suite, "properties")
    for k in ("ghdl", "profile", "commit"):
        ET.SubElement(props, "property", name=k, value=str(results["meta"].get(k, "")))
    for t in tbs:
        case = ET.SubElement(suite, "testcase", classname=f"sprout8.{t['name']}", name=t["unit"],
                             file=t["file"], time=str(t["duration_s"]))
        if t["status"] == "failed":
            f = ET.SubElement(case, "failure", message=f"{t['failed_checks']} of {t['checks']} checks failed")
            f.text = "\n\n".join(t["failures"])
        elif t["status"] in ("error", "timeout"):
            e = ET.SubElement(case, "error", message=t["status"])
            e.text = "\n\n".join(t["failures"]) or "see log"
        so = ET.SubElement(case, "system-out")
        so.text = f"{t['checks']} checks; " + "; ".join(t["notes"])
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def git(*args: str) -> str:
    try:
        return sh(["git", *args]).stdout.strip()
    except Exception:
        return ""


# --------------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"))
    ap.add_argument("--manifest", default=str(ROOT / "hw" / "manifest.json"))
    ap.add_argument("--profile", default="default", help="manifest profile, e.g. 'nightly'")
    ap.add_argument("--only", nargs="+", metavar="TB", help="run only these testbenches")
    ap.add_argument("-g", "--generic", action="append", default=[], metavar="TB.NAME=VALUE",
                    help="override a testbench generic, e.g. tb_cpu.RAND_SEED=42")
    ap.add_argument("--out", default=str(ROOT / "build" / "report"))
    ap.add_argument("--hw-dir", help="use this directory in place of hw/ (mutation testing)")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--waves", choices=["on-failure", "never", "always"], default="on-failure")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    std = manifest.get("vhdl_std", "08")
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    hw_dir = Path(args.hw_dir).resolve() if args.hw_dir else None
    work = out / "work"
    info = ghdl_info(args.ghdl)
    overrides = parse_generic_overrides(args.generic)

    tbs = manifest["testbenches"]
    if args.only:
        unknown = set(args.only) - {t["name"] for t in tbs}
        if unknown:
            sys.exit(f"error: unknown testbench(es): {', '.join(sorted(unknown))}")
        tbs = [t for t in tbs if t["name"] in args.only]

    started = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    t0 = time.monotonic()
    log = (lambda *a: None) if args.quiet else print
    log(f"GHDL: {info['version']} ({info['backend']}), profile: {args.profile}")

    ok, clog = compile_all(args.ghdl, manifest, work, hw_dir, std)
    if not ok:
        print("COMPILE ERROR\n" + clog)
        annotate("error", "VHDL compile error", clog[-3000:])
        (out / "compile.log").write_text(clog)
        return 2

    def generics_for(tb: dict) -> dict:
        g = dict(tb.get("generics", {}))
        g.update(tb.get("profiles", {}).get(args.profile, {}).get("generics", {}))
        g.update(overrides.get(tb["name"], {}))
        return g

    results = []
    with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futs = {pool.submit(run_tb, args.ghdl, info["backend"], tb, work, generics_for(tb), std, out,
                            args.waves == "always"): tb for tb in tbs}
        for fut in cf.as_completed(futs):
            r = fut.result()
            results.append(r)
            mark = {"passed": "PASS", "failed": "FAIL"}.get(r["status"], r["status"].upper())
            log(f"  {mark:7s} {r['name']:12s} {r['checks']:>8,} checks  {r['duration_s']:7.1f} s")
            for f in r["failures"][:3]:
                log("          " + f.replace("\n", "\n          "))

    order = {t["name"]: i for i, t in enumerate(manifest["testbenches"])}
    results.sort(key=lambda r: order[r["name"]])

    # waveforms for failing benches, for debugging from the CI artifact
    if args.waves == "on-failure":
        for r in results:
            if r["status"] != "passed":
                tb = next(t for t in tbs if t["name"] == r["name"])
                run_tb(args.ghdl, info["backend"], tb, work, generics_for(tb), std, out, wave=True)
                r["wave"] = f"waves/{r['name']}.ghw"

    for r in results:
        if r["status"] != "passed":
            first = r["failures"][0] if r["failures"] else r["status"]
            annotate("error", f"{r['name']} {r['status']}", first)

    passed = sum(r["status"] == "passed" for r in results)
    data = {
        "meta": {
            "project": "Sprout-8",
            "started": started,
            "duration_s": round(time.monotonic() - t0, 1),
            "ghdl": info["version"], "backend": info["backend"],
            "profile": args.profile,
            "commit": os.environ.get("GITHUB_SHA") or git("rev-parse", "HEAD"),
            "ref": os.environ.get("GITHUB_REF_NAME") or git("rev-parse", "--abbrev-ref", "HEAD"),
            "run_url": (f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/"
                        f"{os.environ['GITHUB_RUN_ID']}" if IN_GHA else ""),
            "repository": os.environ.get("GITHUB_REPOSITORY", ""),
        },
        "totals": {
            "testbenches": len(results), "passed": passed, "failed": len(results) - passed,
            "checks": sum(r["checks"] for r in results),
            "failed_checks": sum(r["failed_checks"] for r in results),
        },
        "testbenches": results,
    }
    shutil.rmtree(work, ignore_errors=True)
    (out / "results.json").write_text(json.dumps(data, indent=2))
    write_junit(data, out / "junit.xml")
    log(f"{passed}/{len(results)} testbenches passed, {data['totals']['checks']:,} checks "
        f"in {data['meta']['duration_s']} s -> {out}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
