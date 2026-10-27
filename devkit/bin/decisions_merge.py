#!/usr/bin/env python3
"""Merge two branches' docs/decisions.md when each only APPENDED dated entries to their base.

Usage (merge_rules.sh's carry, bin/_merge_carry.sh):
  decisions_merge.py <base> <ours> <theirs>
Prints the merged log on stdout, exit 0; exit 1 with one line on stderr naming why when either
side did anything but append entries (an edited, removed or reordered entry, a changed preamble,
lines added to the base's last entry): those are a person's to merge. Exit 2 on a bad call.

The log is a preamble, then entries, each from its `## YYYY-MM-DD — title` heading to the next.
The result is the base, verbatim, then both sides' new entries, ordered by their dates (stable:
ours first on a tie, each side's own order kept), each after exactly one blank line; an entry
both sides added (a stacked PR and main, which squash-merged the PR below it) appears once. Why not
git's union driver (bin/_gitattributes_lib.sh): it keeps both sides' lines, but xdiff's zealous
merge moves the blank line both sides added before their entry out of the conflict, so the
second entry lands flush against the first (fleet decisions logs, 2026-10-26); it orders by side,
never by date, which docs_check rule 8 reads; and it merges an edit silently into both versions.
Only entry boundaries are compared, so trailing blank lines of an entry never count as an edit.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

HEADING = re.compile(r"^## (\d{4}-\d{2}-\d{2})\b")
# A heading inside a fenced block is quoted text, not an entry (docs_check rule 8 skips them too).
FENCE = re.compile(r"^\s*(```|~~~)")


class NotAppendOnlyError(Exception):
    """A side changed the log other than by appending entries."""


@dataclass(frozen=True)
class Log:
    preamble: tuple[str, ...]
    entries: tuple[tuple[str, ...], ...]  # each entry's lines, trailing blank lines dropped


def _strip_blank_tail(lines: list[str]) -> tuple[str, ...]:
    while lines and not lines[-1].strip():
        lines.pop()
    return tuple(lines)


def lines_of(text: str) -> list[str]:
    """Split on newlines only: str.splitlines also breaks on form feeds and U+2028."""
    return text.removesuffix("\n").split("\n") if text else []


def parse(text: str) -> Log:
    preamble: list[str] = []
    entries: list[list[str]] = []
    fenced = False
    for line in lines_of(text):
        if FENCE.match(line):
            fenced = not fenced
        if not fenced and HEADING.match(line):
            entries.append([line])
        elif entries:
            entries[-1].append(line)
        else:
            preamble.append(line)
    return Log(_strip_blank_tail(preamble), tuple(_strip_blank_tail(e) for e in entries))


def new_entries(base: Log, side: Log, name: str) -> tuple[tuple[str, ...], ...]:
    """The entries <side> appended to <base>; NotAppendOnlyError when it did more."""
    if side.preamble != base.preamble:
        raise NotAppendOnlyError(f"{name} changed the text before the first entry")
    kept = side.entries[: len(base.entries)]
    for index, (was, now) in enumerate(zip(base.entries, kept, strict=False)):
        if was != now:
            raise NotAppendOnlyError(f"{name} changed the entry '{was[0]}' (entry {index + 1})")
    if len(kept) < len(base.entries):
        raise NotAppendOnlyError(f"{name} removed the entry '{base.entries[len(kept)][0]}'")
    return side.entries[len(base.entries):]


def _date(entry: tuple[str, ...]) -> str:
    match = HEADING.match(entry[0])
    assert match is not None  # parse() starts every entry at a heading
    return match.group(1)


def merge(base_text: str, ours_text: str, theirs_text: str) -> str:
    base, ours, theirs = parse(base_text), parse(ours_text), parse(theirs_text)
    mine = list(new_entries(base, ours, "ours"))
    # A stacked PR holds an entry main got by squash-merging the PR below it: once, not twice.
    yours = [e for e in new_entries(base, theirs, "theirs") if e not in mine]
    # ...unless it was amended before that squash: two versions of one entry are a person's call.
    for entry in yours:
        if any(other[0] == entry[0] for other in mine):
            raise NotAppendOnlyError(f"both sides added '{entry[0]}' with different text")
    added: list[tuple[str, ...]] = []
    while mine and yours:
        added.append(yours.pop(0) if _date(yours[0]) < _date(mine[0]) else mine.pop(0))
    added += mine + yours
    lines = list(_strip_blank_tail(lines_of(base_text)))
    for entry in added:
        lines += ["", *entry] if lines else list(entry)
    return "\n".join(lines) + "\n"


def _read_exact(path: str) -> str:
    with Path(path).open(encoding="utf-8", newline="") as handle:
        return handle.read()


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: decisions_merge.py <base> <ours> <theirs>", file=sys.stderr)
        return 2
    try:
        # newline="": a CRLF base stays byte for byte (the line split keeps each \r). Through
        # open(), not read_text(newline=...), which is 3.13's: the floor is 3.11 (kitchen #25).
        texts = [_read_exact(path) for path in argv]
    except (OSError, UnicodeDecodeError) as err:
        print(f"decisions_merge: {err}", file=sys.stderr)
        return 2
    try:
        sys.stdout.write(merge(*texts))
    except NotAppendOnlyError as err:
        print(f"decisions_merge: not append-only: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
