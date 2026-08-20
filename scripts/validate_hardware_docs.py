#!/usr/bin/env python3
"""Validate H0C Rev A per-page online wiring checklists."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
WIRING = DOCS / "wiring"
ARCHIVE = DOCS / "archive" / "11_h0c_reva_schematic_wiring_handoff_stage_2026-08-20.md"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def numbered_rows(path: Path) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\|\s*(\d+)\s*\|", line)
        if match:
            rows.append((int(match.group(1)), line))
    return rows


def validate_page(path: Path, expected_last: int) -> None:
    if not path.exists():
        fail(f"missing page checklist: {path.relative_to(ROOT)}")
    rows = numbered_rows(path)
    numbers = [number for number, _ in rows]
    expected = list(range(1, expected_last + 1))
    if numbers != expected:
        fail(f"{path.name} must be continuous 1..{expected_last}; got {numbers}")


def validate_01() -> None:
    path = WIRING / "01_power_usb.md"
    validate_page(path, 208)
    text = path.read_text(encoding="utf-8")
    rows = [line for _, line in numbered_rows(path)]
    required = (
        "`D1-pin 1（K）`",
        "`D1-pin 2（A）`",
        "`Q1-D/EP（pin 9）`",
        "`R5-pin 2`",
        "`R5-pin 1`",
        "NET-VBUS_BUCK_IN",
    )
    for token in required:
        if not any(token in line for line in rows):
            fail(f"01 current baseline is missing {token}")

    forbidden = ("D4-", "R30-", "R31-", "R32-", "F1-", "F2-", "R54-")
    for token in forbidden:
        if any(token in line for line in rows):
            fail(f"removed item {token!r} appears in 01 executable rows")

    if "致命错误 0、错误 0、警告 30" not in text:
        fail("01 fresh ERC baseline is missing")


def validate_part_placements() -> None:
    audio_in = (WIRING / "03_audio_in.md").read_text(encoding="utf-8")
    audio_out = (WIRING / "04_audio_out.md").read_text(encoding="utf-8")
    for token in ("C62–C65", "CL10B105KP8NNNC", "C95843", "图框外并保存，未接线"):
        if token not in audio_in:
            fail(f"03 placement record is missing {token}")
    for token in ("C66–C68", "CL10B105KP8NNNC", "C95843", "图框外并保存，未接线"):
        if token not in audio_out:
            fail(f"04 placement record is missing {token}")


def validate_markdown_links() -> None:
    link_pattern = re.compile(r"\[[^\]]+\]\(([^)]+\.md)(?:#[^)]+)?\)")
    missing: list[str] = []
    for markdown in sorted(DOCS.rglob("*.md")):
        if markdown.parent.name == "archive":
            continue
        text = markdown.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(text):
            if "://" in raw_target:
                continue
            target = (markdown.parent / raw_target).resolve()
            if not target.exists():
                missing.append(f"{markdown.relative_to(DOCS)} -> {raw_target}")
    if missing:
        fail("missing Markdown links: " + ", ".join(missing))


def main() -> int:
    if not ARCHIVE.exists():
        fail("old 1-212 stage checklist was not archived")

    expected_pages = {
        "00_base_system.md": 5,
        "01_power_usb.md": 208,
        "02_mcu_debug.md": 42,
        "03_audio_in.md": 22,
        "04_audio_out.md": 22,
        "05_head_link.md": 30,
        "06_motion_io.md": 33,
        "07_connectors_test.md": 16,
        "head_00_system.md": 6,
        "head_01_display_touch.md": 7,
        "head_02_camera_privacy.md": 7,
        "head_03_flex_test.md": 8,
    }
    for name, expected_last in expected_pages.items():
        validate_page(WIRING / name, expected_last)

    validate_01()
    validate_part_placements()
    validate_markdown_links()
    print("PASS: 12 online schematic pages have independent numbering starting at 1")
    print("PASS: 01POWERUSB is continuous 1..208 with the D1.1/Q1.9/R5 repair baseline")
    print("PASS: 02 is 1..42 and 06 is 1..33")
    print("PASS: C62..C68 placement records contain exact part and no-wiring status")
    print("PASS: old 1..212 stage checklist is archived and Markdown links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
