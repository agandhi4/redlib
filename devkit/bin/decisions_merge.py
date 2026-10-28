#!/usr/bin/env python3
"""Merge two branches' docs/decisions.md when each only APPENDED dated entries to their base,
or, as git's merge driver, also edited entries the other side left alone.

Usage:
  decisions_merge.py <base> <ours> <theirs>            merge_rules.sh's carry (bin/_merge_carry.sh)
  decisions_merge.py --driver <base> <ours> <theirs>   git's merge.devkit-decisions driver
                                                       (bin/_gitattributes_lib.sh): %O %A %B
Prints the merged log on stdout (--driver: writes it over <ours>, where git reads it), exit 0;
exit 1 with one line on stderr naming why when a side did what the mode does not merge: those are
a person's, and <ours> is left as it was. Exit 2 on a bad call.

The log is a preamble, then entries, each from its `## YYYY-MM-DD — title` heading to the next.
An entry is known by its heading (the n-th of a repeated heading by n). The result keeps the base's
entries in order, verbatim where neither side changed them, and puts each side's new entries where
that side put them (after the same base entry), the two sides' ordered by date (stable: ours first
on a tie, each side's own order kept), each after exactly one blank line; an entry both sides added
(a stacked PR and main, which squash-merged the PR below it) appears once.
- The carry (no flag) takes appends only, after the base's last entry: an edited, removed or
  reordered entry, a changed preamble, lines added to the base's last entry or an entry inserted
  before it are refused. It merges unattended on GitHub, so nothing but an append merges there.
- --driver also takes an entry, or the preamble, that one side changed and the other did not, and
  a new entry inserted between base entries. Why (devkit #262's own rebase, 2026-10-27): a lane's
  second commit amending the entry its first added is an edit of the base's last entry, and once
  main has appended, every rebase of such a branch conflicted. Removed, reordered, or changed by
  both sides is still refused, and git falls back to its text merge (conflict markers).
Why not git's union driver (the log's until 2026-10-27, bin/_gitattributes_lib.sh): it keeps both
sides' lines, but xdiff's zealous merge moves the blank line both sides added before their entry
out of the conflict, so the second entry lands flush against the first (fleet decisions logs,
2026-10-26); it orders by side, never by date, which docs_check rule 8 reads; and it merges an
edit silently into both versions.
Trailing blank lines of an entry never count as an edit.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

HEADING = re.compile(r"^## (\d{4}-\d{2}-\d{2})\b")
# A heading inside a fenced block is quoted text, not an entry (docs_check rule 8 skips them too).
FENCE = re.compile(r"^\s*(```|~~~)")


class NotAppendOnlyError(Exception):
    """A side changed the log in a way this mode does not merge."""


def _strip_blank_tail(lines: list[str] | tuple[str, ...]) -> tuple[str, ...]:
    lines = list(lines)
    while lines and not lines[-1].strip():
        lines.pop()
    return tuple(lines)


@dataclass(frozen=True)
class Entry:
    key: tuple[str, int]  # (heading, which occurrence of it): history repeats a few headings
    raw: tuple[str, ...]  # its lines as in the file, trailing blank lines kept

    @property
    def text(self) -> tuple[str, ...]:
        """What an edit is judged on, and what a moved or edited entry is written as."""
        return _strip_blank_tail(self.raw)


@dataclass(frozen=True)
class Log:
    preamble: tuple[str, ...]  # raw, as in the file
    entries: tuple[Entry, ...]


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
    seen: Counter[str] = Counter()
    keyed = []
    for lines in entries:
        keyed.append(Entry((lines[0], seen[lines[0]]), tuple(lines)))
        seen[lines[0]] += 1
    return Log(tuple(preamble), tuple(keyed))


@dataclass(frozen=True)
class Side:
    """One side against the base: its version of every base entry, and its new entries grouped
    by the base entry they follow (None: before the first)."""
    versions: dict[tuple[str, int], Entry]
    added: dict[tuple[str, int] | None, list[Entry]]


def _side(base: Log, log: Log, name: str, *, edits: bool) -> Side:
    base_keys = [e.key for e in base.entries]
    known = set(base_keys)
    versions: dict[tuple[str, int], Entry] = {}
    added: dict[tuple[str, int] | None, list[Entry]] = {}
    order: list[tuple[str, int]] = []
    anchor: tuple[str, int] | None = None
    for e in log.entries:
        if e.key in known:
            versions[e.key] = e
            order.append(e.key)
            anchor = e.key
        else:
            added.setdefault(anchor, []).append(e)
    for key in base_keys:
        if key not in versions:
            raise NotAppendOnlyError(f"{name} removed the entry '{key[0]}'")
    if order != base_keys:
        raise NotAppendOnlyError(f"{name} reordered the entries")
    if not edits:
        if _strip_blank_tail(log.preamble) != _strip_blank_tail(base.preamble):
            raise NotAppendOnlyError(f"{name} changed the text before the first entry")
        for index, was in enumerate(base.entries):
            if versions[was.key].text != was.text:
                raise NotAppendOnlyError(
                    f"{name} changed the entry '{was.key[0]}' (entry {index + 1})")
        last = base_keys[-1] if base_keys else None
        for at, entries in added.items():
            if at != last:
                raise NotAppendOnlyError(
                    f"{name} added the entry '{entries[0].key[0]}' before the base's last entry")
    return Side(versions, added)


def _pick(what: str, base: tuple[str, ...], ours: tuple[str, ...],
          theirs: tuple[str, ...]) -> tuple[str, ...]:
    """The changed side's version (both alike counts as one), compared without trailing blanks;
    <base> itself when neither changed it."""
    b, o, t = (_strip_blank_tail(v) for v in (base, ours, theirs))
    if o == b == t:
        return base
    if o == b:
        return theirs
    if t in (b, o):
        return ours
    raise NotAppendOnlyError(f"both sides changed {what}")


def _date(entry: Entry) -> str:
    match = HEADING.match(entry.key[0])
    assert match is not None  # parse() starts every entry at a heading
    return match.group(1)


def _by_date(mine: list[Entry], yours: list[Entry]) -> list[Entry]:
    mine, yours, merged = list(mine), list(yours), []
    while mine and yours:
        merged.append(yours.pop(0) if _date(yours[0]) < _date(mine[0]) else mine.pop(0))
    return merged + mine + yours


def merge(base_text: str, ours_text: str, theirs_text: str, *, edits: bool = False) -> str:
    base, ours, theirs = parse(base_text), parse(ours_text), parse(theirs_text)
    mine, yours = _side(base, ours, "ours", edits=edits), _side(base, theirs, "theirs", edits=edits)
    # A stacked PR holds an entry main got by squash-merging the PR below it: once, not twice.
    ours_added = {e.text: e for group in mine.added.values() for e in group}
    ours_headings = {e.key[0] for e in ours_added.values()}
    for group in yours.added.values():
        for e in group:
            # ...unless amended before that squash: two versions of one entry are a person's call.
            if e.text not in ours_added and e.key[0] in ours_headings:
                raise NotAppendOnlyError(f"both sides added '{e.key[0]}' with different text")
        group[:] = [e for e in group if e.text not in ours_added]

    # (lines, base position) chunks: 0 the preamble, n the base's n-th entry (whichever side's
    # version), None a new entry. Base chunks back to back keep their own spacing, as in the
    # file the version came from; a new entry, and the base entry after one, get one blank line.
    preamble = _pick("the text before the first entry", base.preamble, ours.preamble,
                     theirs.preamble)
    chunks: list[tuple[tuple[str, ...], int | None]] = [(preamble, 0)]

    def added_after(anchor: tuple[str, int] | None) -> None:
        for e in _by_date(mine.added.get(anchor, []), yours.added.get(anchor, [])):
            chunks.append((e.text, None))

    added_after(None)
    for position, was in enumerate(base.entries, start=1):
        version = _pick(f"the entry '{was.key[0]}'", was.raw, mine.versions[was.key].raw,
                        yours.versions[was.key].raw)
        chunks.append((version, position))
        added_after(was.key)

    lines: list[str] = []
    previous: int | None = None
    for chunk, position in chunks:
        if position is not None and (position == 0 or previous == position - 1):
            lines += chunk
        elif chunk:
            lines = list(_strip_blank_tail(lines))
            lines += ["", *_strip_blank_tail(chunk)] if lines else list(_strip_blank_tail(chunk))
        previous = position
    return "\n".join(_strip_blank_tail(lines)) + "\n"


def _read_exact(path: str) -> str:
    with Path(path).open(encoding="utf-8", newline="") as handle:
        return handle.read()


def main(argv: list[str]) -> int:
    driver = argv[:1] == ["--driver"]
    paths = argv[1:] if driver else argv
    if len(paths) != 3:
        print("usage: decisions_merge.py [--driver] <base> <ours> <theirs>", file=sys.stderr)
        return 2
    try:
        # newline="": a CRLF base stays byte for byte (the line split keeps each \r). Through
        # open(), not read_text(newline=...), which is 3.13's: the floor is 3.11 (kitchen #25).
        texts = [_read_exact(path) for path in paths]
    except (OSError, UnicodeDecodeError) as err:
        print(f"decisions_merge: {err}", file=sys.stderr)
        return 2
    try:
        merged = merge(*texts, edits=driver)
    except NotAppendOnlyError as err:
        print(f"decisions_merge: not append-only: {err}", file=sys.stderr)
        return 1
    if not driver:
        sys.stdout.write(merged)
        return 0
    try:
        with Path(paths[1]).open("w", encoding="utf-8", newline="") as handle:
            handle.write(merged)
    except OSError as err:
        print(f"decisions_merge: {err}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
