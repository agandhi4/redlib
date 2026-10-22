#!/usr/bin/env python3
"""Bats assertions errexit never sees: each one passes whether or not it holds.

bats fails a test on the first command that trips `set -e` (its ERR trap), or on the status of
the test's last command. Three assertion shapes trip neither when they fail mid-test:
  - `[[ ... ]]` and `(( ... ))`: bash before 4.1 (macOS /bin/bash 3.2, which every lane's bats
    runs on) exempts both compound commands from errexit. bash 5 in CI fails them, so the same
    test passes locally and fails, or never ran its check, depending on the host.
  - `! cmd`: a negated pipeline never trips errexit, in any bash (POSIX).
  - `[ a ] && [ b ]`: a failing command before `&&` never trips errexit, in any bash.
devkit #205 shipped two assertions that had never held (found by #212), #196 a third.

The form every one of them takes instead: `<test> || false` (or any `|| <handler>` that fails,
such as `|| { echo "$output"; false; }`). It fails on every bash and in any position, so the rule
needs no "is this the test's last command" judgement. `false` rather than `return 1`, bats-core's
own idiom: shellcheck 0.11 reads a `return` mid-@test as ending the flow, so a later test calling a
function it sourced got SC2218 (gate_contract.bats). Splitting `[ a ] && [ b ]` into one `[ ]` per
line also clears it.

What is read: each *.bats file and every file it `load`s, outside heredocs (also those opened
inside `$( )`) and multi-line quotes. A statement starting with one of the shapes above is
checked, joined over lines ending in `&&`, `||`, `|` or a backslash; `if`/`while` conditions start
with their keyword, so they are not flagged. Not read: an assertion after `;` on the same line
(`f; [[ x ]]`), or inside a one-line function (`f() { [[ x ]]; }`, whose `[[` is its return
status and safe). `--fix` leaves a statement alone when appending could change what it does:
an `&&` list, a `;` after the test, or a line running on into one not read.

Usage: bats_assert_check.py [--root DIR] [FILE ...]
  With no FILE: every git-tracked *.bats under --root (default .), skipping devkit/ (a vendored
  copy is checked upstream). Output: one `path:line: <why>` per assertion, then exit 1; exit 0
  when clean; exit 2 on a usage error or an unreadable file. Used by: Makefile ci-lint (devkit's
  own tests, failing) and bin/devkit-check.sh (a consumer's, as warnings).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
LOAD = re.compile(r"^\s*load\s+['\"]?([^'\"\s]+)['\"]?\s*$")
CONTINUES = ("&&", "||", "|", "\\")
FIX = "add `|| false`"


class Line(NamedTuple):
    number: int
    raw: str
    bare: str  # top-level code only (see _lex), same columns as raw, cut at a comment


def code_lines(text: str) -> list[Line]:
    """Each line that starts outside a heredoc, a multi-line quote or a multi-line `$( )`."""
    out: list[Line] = []
    stack: list[str] = []
    bodies: list[str] = []  # delimiters of heredocs still to skip, in order
    for number, raw in enumerate(text.splitlines(), 1):
        if bodies:
            if raw.strip() == bodies[0]:
                bodies.pop(0)
            continue
        starts_clean = not stack
        bare, stack, opened = _lex(raw, stack)
        bodies.extend(opened)
        if starts_clean:
            out.append(Line(number, raw, bare))
    return out


def _lex(line: str, stack: list[str]) -> tuple[str, list[str], list[str]]:
    """The line with everything not at top level (quoted, or inside `$( )` or backticks) blanked
    and a top-level comment cut off; the contexts still open at its end; and the delimiters of
    the heredocs it opens, at any `$( )` depth (`x=$(cat <<EOF`). Inside `$( )` quoting starts
    afresh, so `"$(grep "a'b" f)"` closes where bash closes it; `$'..'` honours `\'`."""
    stack = list(stack)
    kept: list[str] = []
    heredocs: list[str] = []
    i = 0
    while i < len(line):
        c, top, width = line[i], (stack[-1] if stack else ""), 1
        was_top = not stack
        heredoc = HEREDOC.match(line, i) if c == "<" and top in ("", "(") else None
        if top == "'":
            if c == "'":
                stack.pop()
        elif c == "\\":
            width = 2  # the escaped character is never a delimiter
        elif top == "$'":
            if c == "'":
                stack.pop()
        elif c == top and c in "\"`":
            stack.pop()
        elif heredoc and line[i - 1:i] != "<" and line[i + 2:i + 3] != "<":
            heredocs.append(heredoc.group(2))
            width = heredoc.end() - i  # the delimiter's own quotes open nothing
        elif c == "$" and line[i + 1:i + 2] == "(":
            stack.append("(")
            width = 2
        elif c == "$" and line[i + 1:i + 2] == "'" and top != '"':
            stack.append("$'")
            width = 2
        elif c == "(" and top == "(":
            stack.append("(")
        elif c == ")" and top == "(":
            stack.pop()
        elif c == "`" or (c in "'\"" and top != '"'):
            stack.append(c)
        elif was_top and c == "#" and (i == 0 or line[i - 1] in " \t;"):
            break
        visible = was_top and not stack
        kept.append(line[i:i + width] if visible else " " * len(line[i:i + width]))
        i += width
    return "".join(kept), stack, heredocs


def _after_close(bare: str, opener: str, closer: str) -> str | None:
    """What follows the `closer` matching the leading `opener`, or None when it is not closed."""
    depth = 0
    for match in re.finditer(re.escape(opener) + "|" + re.escape(closer), bare):
        depth += 1 if match.group() == opener else -1
        if depth == 0:
            return bare[match.end():]
    return None


class Finding(NamedTuple):
    line: int
    why: str
    fix_at: tuple[int, int] | None  # (line, column) `|| false` goes at; None: needs judgement


def verdict(bare: str) -> tuple[str, bool] | None:
    """Why this statement's failure would go unseen, and whether appending `|| false` alone
    fixes it; None when it is seen. Only the first `;`-separated command is the assertion:
    `[[ x ]]; a || b` handles `a`, not the test."""
    for opener, closer, why in (
        ("[[", "]]", "`[[ ]]` mid-test never fails on bash 3.2"),
        ("((", "))", "`(( ))` mid-test never fails on bash 3.2"),
    ):
        if bare.startswith(opener + " ") or bare == opener:
            rest = _after_close(bare, opener, closer)
            if rest is None:
                return f"{why}; {FIX}", False
            first = rest.split(";")[0]
            if "||" in first:
                return None
            return f"{why}; {FIX}", rest == first and "&&" not in rest
    first = bare.split(";")[0]
    if bare.startswith("! "):
        if "||" in first:
            return None
        return f"`! cmd` never trips errexit; {FIX}", bare == first and "&&" not in bare
    if re.match(r"(\[|test)\s", bare) and "&&" in first and "||" not in first:
        # `[ c ] && action` may be a conditional, not an assertion: `if` or split, by hand.
        why = f"a failing `[ ]` before `&&` never trips errexit; one `[ ]` per line, or {FIX}"
        return why, False
    return None


def _statements(lines: list[Line]) -> list[list[Line]]:
    """Physical lines grouped into statements: a line ending in `&&`, `||`, `|` or `\\` takes
    the next one, unless that one was not read (it starts inside a quote or a heredoc)."""
    out: list[list[Line]] = []
    for line in lines:
        last = out[-1][-1] if out else None
        if last and last.bare.rstrip().endswith(CONTINUES) and line.number == last.number + 1:
            out[-1].append(line)  # even one all quoted, whose `bare` is blank: `  "$f"`
        elif line.bare.strip():
            out.append([line])
    return out


def check_text(text: str) -> list[Finding]:
    found: list[Finding] = []
    for statement in _statements(code_lines(text)):
        joined = " ".join(line.bare.strip().rstrip("\\") for line in statement)
        judged = verdict(joined)
        if not judged:
            continue
        why, fixable = judged
        last = statement[-1]
        if last.bare.rstrip().endswith(CONTINUES):
            fixable = False  # it runs on into a line not read: its end is unknown
        # The raw text, not `bare`: a quoted last word is blanked there.
        column = len(last.raw[:len(last.bare)].rstrip())
        found.append(Finding(statement[0].number, why, (last.number, column) if fixable else None))
    return found


def fix_text(text: str, found: list[Finding]) -> str:
    lines = text.splitlines(keepends=True)
    for finding in found:
        if finding.fix_at is not None:
            number, column = finding.fix_at
            line = lines[number - 1]
            lines[number - 1] = line[:column] + " || false" + line[column:]
    return "".join(lines)


def loaded_files(bats: Path, text: str) -> list[Path]:
    """The helpers a .bats `load`s (bats resolves `load x` to x.bash beside the file)."""
    out = []
    for line in text.splitlines():
        match = LOAD.match(line)
        if match:
            name = match.group(1)
            target = bats.parent / (name if name.endswith(".bash") else name + ".bash")
            if target.is_file():
                out.append(target)
    return out


def tracked_bats(root: Path) -> list[Path]:
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.bats", ":!:devkit/**"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [root / p for p in listed.split("\0") if p]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument(
        "--fix", action="store_true", help="append `|| false` where that alone fixes it"
    )
    parser.add_argument("files", nargs="*", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        files = [f.resolve() for f in args.files] or tracked_bats(root)
    except subprocess.CalledProcessError as err:
        why = err.stderr.strip()
        print(f"bats_assert_check: git ls-files failed under {root}: {why}", file=sys.stderr)
        return 2
    seen: set[Path] = set()
    found = 0
    queue = list(files)
    while queue:
        path = queue.pop(0)
        if path in seen:
            continue
        seen.add(path)
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as err:
            print(f"bats_assert_check: cannot read {path}: {err}", file=sys.stderr)
            return 2
        if path.suffix == ".bats":
            queue.extend(loaded_files(path, text))
        shown = path.relative_to(root) if path.is_relative_to(root) else path
        findings = check_text(text)
        if args.fix and any(f.fix_at is not None for f in findings):
            path.write_text(fix_text(text, findings), encoding="utf-8")
            findings = [f for f in findings if f.fix_at is None]
        for finding in findings:
            print(f"{shown}:{finding.line}: {finding.why}")
            found += 1
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
