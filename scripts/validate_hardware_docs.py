#!/usr/bin/env python3
"""Validate H0C Rev A hardware handoff invariants without modifying the EDA project."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
HANDOFF = DOCS / "11_h0c_reva_schematic_wiring_handoff.md"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def validate_a_rows(text: str) -> None:
    start = text.index("### 3.1")
    end = text.index("### 3.6")
    section = text[start:end]
    rows = []
    for line in section.splitlines():
        match = re.match(r"^\|\s*(\d+)\s*\|", line)
        if match:
            rows.append((int(match.group(1)), line))

    numbers = [number for number, _ in rows]
    expected = list(range(1, 44)) + list(range(46, 126))
    if numbers != expected:
        fail(f"01POWERUSB A rows must be 1..43 and 46..125; 44/45 are revoked; got {numbers}")

    forbidden = (
        "D4-",
        "R30-",
        "R31-",
        "R32-",
        "F1-",
        "F2-",
        "C39-",
        "C40-",
        "`U7-PG`",
        "`U10-NC`",
        "U11-PG/AUXOFF",
        "U12-PG/AUXOFF",
    )
    for number, line in rows:
        for token in forbidden:
            if token in line:
                fail(f"forbidden or deferred token {token!r} appears in A row {number}")

    if "### 3.5 两路 eFuse：78–125（仅 TPS259470A 变体）" not in text:
        fail("eFuse executable heading is missing")

    if "`U11-PG/AUXOFF（pin 3）`、`U12-PG/AUXOFF（pin 3）` 均保持无网络标签、无导线" not in text:
        fail("TPS259470A AUXOFF NC rule is missing")

    if "原第 44、45 项已撤销" not in section or "`R32` | 已删除" not in text:
        fail("R32/EN overvoltage correction record is missing")


def validate_02_a_rows(text: str) -> None:
    start = text.index("#### 4.1.2")
    end = text.index("### 4.2")
    section = text[start:end]
    numbers = []
    for line in section.splitlines():
        match = re.match(r"^\|\s*02-A(\d{2})\s*\|", line)
        if match:
            numbers.append(int(match.group(1)))
    expected = list(range(1, 43))
    if numbers != expected:
        fail(f"02-MCU-DEBUG A rows must be continuous 01..42; got {numbers}")

    deferred = ("J5-", "TP1-", "TP2-", "TP3-", "TP4-", "TP5-", "TP6-")
    for token in deferred:
        if token in section:
            fail(f"deferred 02 token {token!r} appears in executable A rows")


def validate_06_a_rows(text: str) -> None:
    start = text.index("#### 4.5.2")
    end = text.index("### 4.6")
    section = text[start:end]
    numbers = []
    executable_rows = []
    for line in section.splitlines():
        match = re.match(r"^\|\s*06-A(\d{2})\s*\|", line)
        if match:
            numbers.append(int(match.group(1)))
            executable_rows.append(line)
    expected = list(range(1, 34))
    if numbers != expected:
        fail(f"06-MOTION-IO A rows must be continuous 01..33; got {numbers}")

    deferred = (
        "U8-GPIO2`",
        "U8-GPIO8`",
        "U8-GPIO9`",
        "U8-GPIO47`",
        "U9-BIN1",
        "U9-AOUT1",
        "U9-AOUT2",
        "U9-BOUT1",
        "U9-BOUT2",
        "J_MOTOR",
    )
    for token in deferred:
        if any(token in line for line in executable_rows):
            fail(f"deferred 06 token {token!r} appears in executable A rows")

    if "U9-GND（pin 11）" not in section or "U9-AIN2（pin 13）" not in section:
        fail("06 PWP pin correction must keep GND=11 and AIN2=13")


def validate_markdown_links() -> None:
    link_pattern = re.compile(r"\[[^\]]+\]\(([^)]+\.md)(?:#[^)]+)?\)")
    missing: list[str] = []
    for markdown in sorted(DOCS.glob("*.md")):
        text = markdown.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(text):
            if "://" in raw_target:
                continue
            target = (markdown.parent / raw_target).resolve()
            if not target.exists():
                missing.append(f"{markdown.name} -> {raw_target}")
    if missing:
        fail("missing Markdown links: " + ", ".join(missing))


def main() -> int:
    if not HANDOFF.exists():
        fail(f"missing handoff document: {HANDOFF}")
    text = HANDOFF.read_text(encoding="utf-8")
    validate_a_rows(text)
    validate_02_a_rows(text)
    validate_06_a_rows(text)
    validate_markdown_links()
    print("PASS: 01 A rows are 1..43 and 46..125; revoked 44/45 are absent")
    print("PASS: deferred/removed parts are absent from executable A rows")
    print("PASS: 02 A rows are continuous 01..42 and exclude deferred connectors/test points")
    print("PASS: 06 A rows are continuous 01..33, use corrected PWP pins, and exclude Gate outputs")
    print("PASS: local Markdown document links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
