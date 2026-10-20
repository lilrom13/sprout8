#!/usr/bin/env python3
"""Build the Sprout-8 test report from tools/run_tests.py output.

Reads <dir>/results.json (and <dir>/mutation.json if present) and writes:

    <dir>/index.html   self-contained HTML report (published to GitHub Pages)
    <dir>/summary.md   Markdown summary (also appended to $GITHUB_STEP_SUMMARY with --step-summary)
    <dir>/badge.json   shields.io endpoint badge ("10/10 passing")

Usage: python3 tools/report.py [build/report] [--step-summary]
"""
from __future__ import annotations

import argparse
import html
import json
import os
from pathlib import Path

STATUS_ICON = {"passed": "✅", "failed": "❌", "error": "💥", "timeout": "⏱️"}


def load(d: Path) -> tuple[dict, dict | None]:
    if (d / "results.json").exists():
        res = json.loads((d / "results.json").read_text())
    else:  # the run stopped before any testbench ran (usually a compile error)
        clog = (d / "compile.log").read_text() if (d / "compile.log").exists() else "no results.json found"
        res = {"meta": {"started": "", "duration_s": 0, "ghdl": "?", "backend": "?", "profile": "?",
                        "commit": os.environ.get("GITHUB_SHA", ""), "ref": os.environ.get("GITHUB_REF_NAME", ""),
                        "run_url": "", "repository": os.environ.get("GITHUB_REPOSITORY", "")},
               "totals": {"testbenches": 1, "passed": 0, "failed": 1, "checks": 0, "failed_checks": 1},
               "testbenches": [{"name": "compile", "unit": "VHDL compilation", "status": "error",
                                "checks": 0, "failed_checks": 1, "duration_s": 0, "sim_time": None,
                                "failures": [clog[-4000:]], "notes": [], "generics": {},
                                "file": "", "log": "compile.log"}]}
    mut_path = d / "mutation.json"
    mut = json.loads(mut_path.read_text()) if mut_path.exists() else None
    return res, mut


# --------------------------------------------------------------------------- markdown
def markdown(res: dict, mut: dict | None) -> str:
    t, m = res["totals"], res["meta"]
    ok = t["failed"] == 0
    lines = [
        f"## {'✅' if ok else '❌'} Sprout-8 testbenches: {t['passed']}/{t['testbenches']} passed",
        "",
        f"**{t['checks']:,} checks** in {m['duration_s']} s · {m['ghdl']} ({m['backend']}) · profile `{m['profile']}`",
        "",
        "| | Testbench | Unit | Checks | Time | Notes |",
        "|---|---|---|---:|---:|---|",
    ]
    for tb in res["testbenches"]:
        notes = "; ".join(n for n in tb["notes"] if "sweep done" not in n)
        if tb["status"] != "passed":
            notes = f"**{tb['failed_checks']} failed** " + notes
        lines.append(f"| {STATUS_ICON.get(tb['status'], '?')} | `{tb['name']}` | {tb['unit']} | "
                     f"{tb['checks']:,} | {tb['duration_s']} s | {notes} |")
    failing = [tb for tb in res["testbenches"] if tb["status"] != "passed"]
    if failing:
        lines += ["", "### Failures", ""]
        for tb in failing:
            lines.append(f"<details open><summary><code>{tb['name']}</code>: {tb['status']}</summary>\n")
            lines.append("```")
            lines += tb["failures"][:10] or ["(no check output, see the log)"]
            lines.append("```")
            gen = ", ".join(f"{k}={v}" for k, v in tb["generics"].items())
            if gen:
                lines.append(f"Reproduce: `python3 tools/run_tests.py --only {tb['name']} " +
                             " ".join(f"-g {tb['name']}.{k}={v}" for k, v in tb["generics"].items()) + "`")
            lines.append("</details>\n")
    if mut:
        mt = mut["totals"]
        lines += ["", f"### Mutation check: {mt['killed']}/{mt['total']} planted bugs caught", "",
                  "| | Mutation | Caught by |", "|---|---|---|"]
        for x in mut["mutations"]:
            icon = "✅" if x["result"] == "killed" else ("⚠️" if x["result"] == "survived" else "❔")
            lines.append(f"| {icon} | {x['description']} | {', '.join(x['caught_by']) or x['result']} |")
    if m.get("run_url"):
        lines += ["", f"[Workflow run]({m['run_url']}) · commit `{m['commit'][:7]}`"]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- html
CSS = """
:root{--bg:#f6f7f4;--card:#fff;--ink:#14231a;--muted:#55645a;--line:#dfe4dc;--ok:#1f7a45;--okbg:#e3f3e8;
--bad:#b3261e;--badbg:#fbe9e7;--warn:#8a5a00;--warnbg:#fff4d6;--code:#eef1ec;--accent:#2e9b57}
@media (prefers-color-scheme:dark){:root{--bg:#0f1912;--card:#16241a;--ink:#e8efe9;--muted:#a3b3a8;--line:#2a3b2f;
--ok:#7fd69d;--okbg:#173524;--bad:#ff8a80;--badbg:#3a1b19;--warn:#ffd27a;--warnbg:#3a2e12;--code:#0f1912;--accent:#7cc46f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 16px 64px}
header{display:flex;gap:16px;align-items:center;margin-bottom:8px}
header h1{font-size:26px;margin:0;letter-spacing:-.01em}.muted{color:var(--muted)}
.meta{font-size:13px;color:var(--muted);margin:0 0 24px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:0 0 28px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.card .v{font-size:26px;font-weight:700}.card .k{font-size:13px;color:var(--muted)}
.ok{color:var(--ok)}.bad{color:var(--bad)}
.banner{border-radius:12px;padding:14px 18px;margin:0 0 20px;font-weight:600}
.banner.ok{background:var(--okbg)}.banner.bad{background:var(--badbg)}
h2{font-size:18px;margin:32px 0 12px}
.tablewrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:12px}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);font-weight:600}
tr:last-child td{border-bottom:0}td.num{text-align:right;font-variant-numeric:tabular-nums}
.pill{display:inline-block;border-radius:999px;padding:1px 10px;font-size:12px;font-weight:600}
.pill.passed,.pill.killed{background:var(--okbg);color:var(--ok)}
.pill.failed,.pill.error,.pill.timeout{background:var(--badbg);color:var(--bad)}
.pill.survived,.pill.invalid{background:var(--warnbg);color:var(--warn)}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px}
pre{background:var(--code);border:1px solid var(--line);border-radius:8px;padding:12px;overflow-x:auto;white-space:pre-wrap}
details{margin:8px 0}summary{cursor:pointer;font-weight:600}
a{color:var(--accent)}footer{margin-top:40px;font-size:13px;color:var(--muted)}
"""

LOGO = """<svg viewBox="0 0 160 162" width="48" height="49" aria-hidden="true"><path d="M80 56 V26" stroke="#2E9B57" stroke-width="9" stroke-linecap="round" fill="none"/><path d="M80 40 C 62 40, 48 29, 45 12 C 63 12, 77 23, 80 40 Z" fill="#2E9B57"/><path d="M80 32 C 94 30, 108 19, 114 4 C 97 4, 83 15, 80 32 Z" fill="#7CC46F"/><path d="M30 58 H130 L124 138 Q123 144 117 144 H43 Q37 144 36 138 Z" fill="#EADFC4" stroke="#2B2620" stroke-width="8" stroke-linejoin="round"/><rect x="46" y="76" width="68" height="46" rx="8" fill="#14231A"/><rect x="64" y="96" width="24" height="10" fill="#7CE38B"/></svg>"""


def e(s) -> str:
    return html.escape(str(s))


def html_report(res: dict, mut: dict | None) -> str:
    t, m = res["totals"], res["meta"]
    ok = t["failed"] == 0
    rows = []
    for tb in res["testbenches"]:
        notes = [n for n in tb["notes"] if "sweep done" not in n]
        gen = ", ".join(f"{k}={v}" for k, v in tb["generics"].items())
        links = f'<a href="{e(tb["log"])}">log</a>' + (f' · <a href="{e(tb["wave"])}">wave</a>' if tb.get("wave") else "")
        rows.append(
            f"<tr><td><span class='pill {e(tb['status'])}'>{e(tb['status'])}</span></td>"
            f"<td><code>{e(tb['name'])}</code></td><td>{e(tb['unit'])}</td>"
            f"<td class='num'>{tb['checks']:,}</td><td class='num'>{tb['failed_checks']}</td>"
            f"<td class='num'>{tb['duration_s']} s</td><td class='num'>{e(tb['sim_time'] or '')}</td>"
            f"<td>{e('; '.join(notes))}{'<br><span class=muted>' + e(gen) + '</span>' if gen else ''}</td>"
            f"<td>{links}</td></tr>")
    failures = ""
    for tb in res["testbenches"]:
        if tb["status"] != "passed":
            failures += (f"<details open><summary><code>{e(tb['name'])}</code>: {tb['failed_checks']} failed checks"
                         f"</summary><pre>{e(chr(10).join(tb['failures'][:20]) or 'see log')}</pre></details>")
    mut_html = ""
    if mut:
        mt = mut["totals"]
        mrows = "".join(
            f"<tr><td><span class='pill {e(x['result'])}'>{e(x['result'])}</span></td>"
            f"<td>{e(x['description'])}</td><td><code>{e(x['file'])}</code></td>"
            f"<td>{e(', '.join(x['caught_by']))}</td></tr>" for x in mut["mutations"])
        mut_html = (f"<h2>Mutation check: {mt['killed']}/{mt['total']} planted bugs caught</h2>"
                    f"<p class='muted'>Each row plants one bug in a copy of the RTL and reruns the testbenches. "
                    f"A surviving mutation is a gap in the tests.</p>"
                    f"<div class='tablewrap'><table><thead><tr><th>Result</th><th>Mutation</th><th>File</th>"
                    f"<th>Caught by</th></tr></thead><tbody>{mrows}</tbody></table></div>")
    commit = m.get("commit", "")
    repo = m.get("repository", "")
    commit_link = (f'<a href="https://github.com/{e(repo)}/commit/{e(commit)}"><code>{e(commit[:7])}</code></a>'
                   if repo and commit else f"<code>{e(commit[:7])}</code>")
    run_link = f' · <a href="{e(m["run_url"])}">workflow run</a>' if m.get("run_url") else ""
    mut_card = (f"<div class='card'><div class='v'>{mut['totals']['killed']}/{mut['totals']['total']}</div>"
                f"<div class='k'>mutations caught</div></div>") if mut else ""
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sprout-8 test report</title><style>{CSS}</style></head><body><main>
<header>{LOGO}<div><h1>Sprout-8 test report</h1></div></header>
<p class="meta">{e(m['started'])} · {e(m['ghdl'])} ({e(m['backend'])}) · profile <code>{e(m['profile'])}</code>
· {e(m.get('ref', ''))} {commit_link}{run_link}</p>
<div class="banner {'ok' if ok else 'bad'}">{'All testbenches passed.' if ok else
 f"{t['failed']} of {t['testbenches']} testbenches failed."}</div>
<div class="cards">
<div class="card"><div class="v {'ok' if ok else 'bad'}">{t['passed']}/{t['testbenches']}</div><div class="k">testbenches passed</div></div>
<div class="card"><div class="v">{t['checks']:,}</div><div class="k">checks</div></div>
<div class="card"><div class="v {'bad' if t['failed_checks'] else ''}">{t['failed_checks']}</div><div class="k">failed checks</div></div>
<div class="card"><div class="v">{m['duration_s']} s</div><div class="k">wall time</div></div>{mut_card}
</div>
<h2>Testbenches</h2>
<div class="tablewrap"><table><thead><tr><th>Status</th><th>Testbench</th><th>Unit</th><th>Checks</th>
<th>Failed</th><th>Time</th><th>Sim time</th><th>Notes</th><th>Files</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></div>
{('<h2>Failures</h2>' + failures) if failures else ''}
{mut_html}
<footer>Generated by <code>tools/report.py</code>. Machine-readable results:
<a href="results.json">results.json</a> · <a href="junit.xml">junit.xml</a>{' · <a href="mutation.json">mutation.json</a>' if mut else ''}</footer>
</main></body></html>
"""


def badge(res: dict) -> dict:
    t = res["totals"]
    return {"schemaVersion": 1, "label": "testbenches",
            "message": f"{t['passed']}/{t['testbenches']} passing",
            "color": "brightgreen" if t["failed"] == 0 else "red"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", nargs="?", default="build/report")
    ap.add_argument("--step-summary", action="store_true", help="append the summary to $GITHUB_STEP_SUMMARY")
    args = ap.parse_args()
    d = Path(args.dir)
    res, mut = load(d)
    md = markdown(res, mut)
    (d / "summary.md").write_text(md)
    (d / "index.html").write_text(html_report(res, mut))
    (d / "badge.json").write_text(json.dumps(badge(res)))
    if args.step_summary and os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(md)
    print(f"report written to {d / 'index.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
