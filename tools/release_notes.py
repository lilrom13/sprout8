#!/usr/bin/env python3
"""Print release notes for a tag: the CHANGELOG.md section plus the test summary.

Usage: python3 tools/release_notes.py v1.0.0 [build/report]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def changelog_section(version: str) -> str:
    text = (ROOT / "CHANGELOG.md").read_text()
    v = version.lstrip("v")
    m = re.search(rf"^## \[?v?{re.escape(v)}\]?.*?$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else f"_No CHANGELOG.md entry for {version}._"


def main() -> int:
    version = sys.argv[1]
    report = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "build" / "report"
    print(changelog_section(version))
    summary = report / "summary.md"
    if summary.exists():
        print("\n---\n")
        print(summary.read_text().replace("## ", "### ", 1))
    print("\nAssets: `*-source.zip` is the repository at this tag; "
          "`*-test-report.zip` holds the HTML report, JUnit XML, logs and mutation results.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
