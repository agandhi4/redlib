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

The rule is a canonical form, read line by line, not a bash parser (#216 and #219 tried one; each
Codex round found the next construct it misread). A statement is a line plus the lines it runs
on into (a line ending in `&&`, `||`, `|` or a backslash). One that STARTS with `[[`, `((`, `! `,
or `[ ... ] && <test>` must either
  1. end with a failing handler: `|| H` or `|| { ...; H; }` (also as `|| {`, lines, `}`), where H
     is `false` (bats-core's idiom; prefer it), `return [n]`, `exit [n]`, `skip`, `fail` or
     `flunk`, with nothing before it but the tests: for `[[ ]]`/`(( ))`, tests joined by `&&`,
     `||` and `!` alone; for the others, no pipe/`||`/`&` that hands the status on; or
  2. be its function's last statement (the next code line is a `}` at column 0, the convention
     for a function's close; an indented one may close a `{ }` group) and end with its test
     (no `||` handler, which could succeed): its status is then the test's, or a predicate
     helper's return, and fails on every bash.
A `;` straight after the test (`[[ x ]]; y || false`) leaves the test unhandled: one per line.
Everything else is not judged: an `if`/`while` condition (it starts with its keyword), a
one-line function (`f() { [[ x ]]; }`), a heredoc's body. A `<<WORD` with no `WORD` line after
it (one in a quote or comment, say) is itself a finding, never a silent skip of the file.
What the form trusts, as only a lexer could judge it: a `|| { }` group's body beyond its last
command, and that a multi-line script lives in a heredoc, not a multi-line quote or `$( )`,
whose lines read as statements.
`--fix` appends ` || false` to a one-line statement when that alone makes it the form (after
the closer of `[[ ]]`/`(( ))`, before any comment), leaving the rest, which may be
conditionals, to a person.

Usage: bats_assert_check.py [--root DIR] [--fix] [FILE ...]
  With no FILE: every git-tracked *.bats under --root (default .), skipping devkit/ (a vendored
  copy is checked upstream), and every file they `load`. Output: one `path:line: <why>` per
  assertion, then exit 1; exit 0 when clean; exit 2 on a usage error or an unreadable file.
  Used by: Makefile ci-lint (devkit's own tests, failing) and bin/devkit-check.sh (a consumer's,
  as warnings).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

LOAD = re.compile(r"^\s*load\s+['\"]?([^'\"\s]+)['\"]?\s*$")
HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
# `$((a<<b))` shifts, it opens no heredoc: arithmetic is blanked before HEREDOC looks.
ARITHMETIC = re.compile(r"\(\(.*?\)\)")
# A comment after a line's code, read only after the operator or handler that ends the line, so
# a `#` in a quote earlier on it (`*"#7"*`) is never taken for one.
TAIL = r"(?:\s+#.*)?$"
COMMENT = re.compile(TAIL)
# A line ending in an operator runs on into the next, unless it may hold a comment (`\s#`): one
# ending `# a ||` would swallow the next line's assertion (#223 Codex), so such a line ends its
# statement and the next is judged alone, a loud miss at worst.
CONTINUES = re.compile(r"(&&|\|\|?)$|\\$")
MAY_COMMENT = re.compile(r"\s#")
CLOSES = re.compile(rf"\}}{TAIL}")
OPENS_GROUP = re.compile(r"\|\|\s*\{$")
# `skip-unless` is another command: a name ends at a blank or the line's end (#223 Codex).
_H = r"(?:false|return(?:\s+\d+)?|exit(?:\s+\d+)?|(?:skip|fail|flunk)(?:\s[^|&;{}]*)?)"
HANDLER = re.compile(rf"\|\|\s*(?:{_H}|\{{(?:[^{{}}]*;)?\s*{_H}\s*;\s*\}}){TAIL}")
# A background `&` (not `&&`, `>&2`, `&>f`) before the handler hands it `wait`'s status, or the
# next command's.
BACKGROUND = r"(?<![&>])&(?![&>])"
SEMICOLON = re.compile(r"(?:\[\[.*?\s\]\]|\(\(.*?\)\))\s*;")
# A `[[ ]]`/`(( ))` chain: each test (its `]]`/`))` ending a word or meeting `;|&`, so `*"]]"*`
# inside is the operand's and `]]| cat` swallows no pipe), and what may join them. Whatever
# else is left (a pipe, `&`, a redirection, an `|| echo` mid-chain) takes the status from the
# tests (#223 Codex).
_ENDS_WORD = r"(?=[\s;|&]|$)"
TESTS = re.compile(rf"\[\[\s.*?\s\]\]{_ENDS_WORD}|\(\(.*?\)\){_ENDS_WORD}")
ONLY_TESTS = re.compile(r"(?:\s|&&|\|\||!)*$")
# A last line's own comment, read only when it holds no quote: in `[[ a == " ]] # " ]] || echo`
# the "comment" is an operand's text, which would hide the `|| echo` (#223 Codex).
QUOTELESS_COMMENT = re.compile(r"\s+#[^'\"]*$")
FIX = "end it with `|| false`"


class Shape(NamedTuple):
    starts: re.Pattern[str]
    why: str
    # None: a `[[ ]]`/`(( ))` chain, whose statement before the handler must be tests alone
    # (TESTS, ONLY_TESTS). Otherwise what may not sit before the handler, since the status it
    # sees would be another command's: `! a | b` is one negated pipeline, but
    # `[ a ] && [ b ] | cat` is cat's. A possible comment (`\s#`) masks too: in `! a # || false`
    # the handler is commented out (#223 Codex).
    masks: str | None


SHAPES = (
    # `[[` alone on its line too: a multi-line test is flagged, never read past (#223 Codex).
    Shape(re.compile(r"\[\[(?:\s|$)"), "`[[ ]]` mid-test never fails on bash 3.2", None),
    Shape(re.compile(r"\(\("), "`(( ))` mid-test never fails on bash 3.2", None),
    # `! a | b` is one negated pipeline; in `! a && [ b ] | cat` the pipe is the later test's.
    Shape(re.compile(r"!\s"), "`! cmd` never trips errexit",
          rf"\|\||{BACKGROUND}|&&.*\||{MAY_COMMENT.pattern}"),
    Shape(re.compile(r"(?:\[|test)\s.*&&\s*(?:\[|test\s|!\s|\(\()"),
          "a failing `[ ]` before `&&` never trips errexit",
          rf"\||{BACKGROUND}|{MAY_COMMENT.pattern}"),
)


class Line(NamedTuple):
    number: int
    text: str  # stripped
    top: bool  # starts at column 0: a function's `}` (the convention the last-line rule reads)


class Finding(NamedTuple):
    line: int
    why: str
    fix_at: tuple[int, int] | None  # (line, column) ` || false` goes at; None: needs judgement


def code_lines(text: str) -> tuple[list[Line], list[tuple[int, str]]]:
    """(number, stripped text) of each line outside a heredoc body, blank and comment-only
    lines dropped; and (number, delimiter) of each heredoc never closed. A `<<EOF` in a quote or
    a trailing comment reads as an opener too: unclosed, it is reported, never a silent skip of
    the rest of the file (#223 Codex)."""
    out: list[Line] = []
    bodies: list[tuple[int, str]] = []  # heredocs still to skip, in order: (opened at, delimiter)
    for number, raw in enumerate(text.splitlines(), 1):
        if bodies:
            if raw.strip() == bodies[0][1]:
                bodies.pop(0)
            continue
        line = raw.strip()
        if not line or line.startswith("#"):
            continue  # a comment line's `<<EOF` opens nothing
        bodies.extend((number, m.group(2)) for m in HEREDOC.finditer(ARITHMETIC.sub("", raw)))
        out.append(Line(number, line, not raw[:1].isspace()))
    return out, bodies


def _continued(lines: list[Line], first: int) -> tuple[int, str]:
    """The index of the statement's last physical line, and its continued lines joined."""
    text, i = "", first
    while (
        (more := CONTINUES.search(lines[i].text)) and not MAY_COMMENT.search(lines[i].text)
        and i + 1 < len(lines)
    ):
        text += lines[i].text[:more.start()] + (more.group(1) or "") + " "
        i += 1
    return i, text + lines[i].text


def _with_group(lines: list[Line], last: int, text: str) -> tuple[int, str]:
    """An assertion's `|| {` group over lines, rejoined as `|| { a; b; }`, and the index of its
    close. Only an assertion's: another statement's group (`echo x || {`) is no handler to read,
    and collecting it could swallow the assertions after it (#223 Codex)."""
    # A `|| {` after a possible comment (`echo x # else || {`) opens nothing, as continuations.
    if not OPENS_GROUP.search(text) or MAY_COMMENT.search(lines[last].text):
        return last, text
    # The first line starting `}` closes it; what follows there (`} >&2`) stays in the text, so a
    # close that is not the canonical lone `}` fails the handler, loud.
    close = next((j for j in range(last + 1, len(lines)) if lines[j].text.startswith("}")), None)
    if close is None:
        return len(lines) - 1, text
    body_lines = lines[last + 1:close]
    if any(line.text.endswith("\\") for line in body_lines):
        # A continued line inside: its next line is an argument, not a command (#223 Codex), and
        # rejoining that is the lexer this form avoids. Unread, the handler fails, loud.
        return close, text
    # Each line's comment dropped (`false  # why`): only the group's last command is read.
    commands = (COMMENT.sub("", line.text).removesuffix(";") for line in body_lines)
    body = "".join(f"{command}; " for command in commands)
    return close, OPENS_GROUP.sub("", text) + " || { " + body + lines[close].text


def _status_is_the_tests(shape: Shape, test: str) -> bool:
    """Whether <test> (a statement up to its handler, or all of it) returns its tests' status."""
    if shape.masks is None:
        return ONLY_TESTS.match(TESTS.sub(" ", test)) is not None
    return not re.search(shape.masks, test)


def _handled(shape: Shape, text: str) -> bool:
    handler = HANDLER.search(text)
    if handler is None or not _status_is_the_tests(shape, text[:handler.start()]):
        return False
    # A quote left open before it: the "handler" is an argument's text (`! grep "|| false" f`,
    # `! printf '|| skip x'`, #223 Codex). A chain's tests anchor it; the others do not, so an
    # odd count of either quote, or an escaped one, fails closed (`"it's"` too, flagged loud).
    test = text[:handler.start()]
    unbalanced = test.count("'") % 2 or test.count('"') % 2 or re.search(r"\\['\"]", test)
    return shape.masks is None or not unbalanced


def _semicolon(shape: Shape, text: str) -> bool:
    """A `;` that ends the test before any handler (`[[ x ]]; y || false`): y's handler, not the
    test's. Without a chain's closer to anchor it, any `;` before the handler counts."""
    if shape.masks is None:
        return SEMICOLON.match(text) is not None
    handler = HANDLER.search(text)
    return ";" in (text[:handler.start()] if handler else text)


def _verdict(shape: Shape, text: str, closes_function: bool) -> str | None:
    """Why the statement's failure would go unseen; None when it is seen."""
    if _semicolon(shape, text):
        return f"{shape.why}: the `;` after it leaves it unhandled; one per line, {FIX}"
    # A function's last line returns the failure only unhandled: `[[ a ]] || echo x` returns
    # echo's 0 (#223 Codex).
    if closes_function and _status_is_the_tests(shape, QUOTELESS_COMMENT.sub("", text)):
        return None
    if _handled(shape, text):
        return None
    return f"{shape.why}; {FIX}, or make it the function's last line"


def _fix_column(shape: Shape, text: str) -> int | None:
    """Where ` || false` alone makes this one-line statement the canonical form: after its
    closer, before any comment; at the end of the other shapes, when no comment or `;`/`&` sits
    on the line for it to land after."""
    if shape.masks is None:
        # More than one closer a comment could follow (`== "]] # x" ]]`, `]]  # see [[ y ]]`),
        # or a "comment" holding a quote (`== " ]] # " ]]`): which one ends the test is not
        # lexical, so a person decides (#223 Codex).
        closers = list(re.finditer(rf"(?:\]\]|\)\))(?=(?:{QUOTELESS_COMMENT.pattern})?$)", text))
        column = closers[0].end() if len(closers) == 1 else None
    else:
        column = None if re.search(r"[#;]|(?<!&)&(?!&)", text) else len(text)
    if column is None or _semicolon(shape, text):
        return None
    return column if _handled(shape, text[:column] + " || false" + text[column:]) else None


def check_text(text: str) -> list[Finding]:
    lines, unclosed = code_lines(text)
    found = [
        Finding(number, f"`<<{delimiter}` never closes, so nothing after it was read: close the "
                        "heredoc, or reword a `<<` in a quote or comment", None)
        for number, delimiter in unclosed
    ]
    first = 0
    while first < len(lines):
        # Classified on the continued statement: `[ a ] &&` + `[ b ]` is one (#223 Codex).
        last, statement = _continued(lines, first)
        shape = next((shape for shape in SHAPES if shape.starts.match(statement)), None)
        if shape:
            last, statement = _with_group(lines, last, statement)
        # Only a column-0 `}` ends a function: an indented one may close a `{ }` group mid-test,
        # whose status trips nothing (#223 Codex).
        after = lines[last + 1] if last + 1 < len(lines) else None
        closes_function = after is not None and after.top and CLOSES.match(after.text) is not None
        why = shape and _verdict(shape, statement, closes_function)
        if shape and why:
            number = lines[first].number
            column = _fix_column(shape, statement) if first == last else None
            found.append(Finding(number, why, None if column is None else (number, column)))
        first = last + 1
    return sorted(found, key=lambda finding: finding.line)


def fix_text(text: str, found: list[Finding]) -> str:
    lines = text.splitlines(keepends=True)
    for finding in found:
        if finding.fix_at is not None:
            number, column = finding.fix_at
            line = lines[number - 1]
            column += len(line) - len(line.lstrip())  # the column is of the stripped line
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
