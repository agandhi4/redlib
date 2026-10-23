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
needs no "is this the test's last command" judgement. A handler counts only when it ends in
`false`, `return`, `exit`, `skip`, `fail` or `flunk`: `|| echo mismatch` or `|| true` succeeds,
so the failure stays unseen (rollcall #83 Codex). `return 0`, `exit 0` and `skip` end the test or
helper on purpose, which is a choice, not a silent pass; inside `( )` they end only the subshell,
so there only a failure counts. A pipe, `&` or short-circuit that keeps the handler's status from
being the statement's is unhandled too (#219 Codex). `false` rather than `return 1`, bats-core's
own idiom: shellcheck 0.11 reads a `return` mid-@test as ending the flow, so a later test calling a
function it sourced got SC2218 (gate_contract.bats). Splitting `[ a ] && [ b ]` into one `[ ]` per
line also clears it.

What is read: each *.bats file and every file it `load`s, outside heredocs (also those opened
inside `$( )`) and multi-line quotes. A statement starting with one of the shapes above is
checked, joined over lines ending in `&&`, `||`, `|` or a backslash; `if`/`while` conditions start
with their keyword, so they are not flagged. Not read: an assertion after `;` on the same line
(`f; [[ x ]]`), or inside a one-line function (`f() { [[ x ]]; }`, whose `[[` is its return
status and safe). It reads bash lexically, not by its grammar: a shape it cannot judge (a `case`
or a pipe on the assertion's side) is flagged, never passed. `--fix` leaves a statement alone
when appending could change what it does: an `&&` list, a `;` after the test, or a line running
on into one not read.

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
# A handler group opened at a line's end (`|| {`), whose body and `}` follow on later lines.
OPENS_GROUP = re.compile(r"\|\|\s*[{(]\s*$")
# A pipe at any depth (`|&` too, bash 4's): not `||`, nor a `>|` clobber redirection.
LONE_PIPE = re.compile(r"(?<![|>])\|(?!\|)")
# A `[[ ]]` or `(( ))` expression, whose `|` is a regex's, a pattern's or a bitwise OR
# (`=~ ^(x|y)$`, `(( n | 1 ))`), never a pipe.
TEST_EXPR = re.compile(r"\[\[.*?\s\]\]|\(\(.*?\)\)")
# A redirection at a command's end (`>&2`, `2>/dev/null`, `&>log`): it never changes a status.
# A `case ... esac`, whose arms' `)` and `;;` are no group or list syntax: one command.
CASE_BLOCK = re.compile(r"\bcase\b.*?\bin\b.*?\besac\b")
# What _split_top leaves of one: a character no blanked line otherwise holds.
CASE_MARK = "\0"
TRAILING_REDIRECT = re.compile(r"\s*(?:\d*[<>]{1,2}&?|&>>?)\s*[^\s<>]*$")
FIX = "add `|| false`"
PIPED = f"a pipe (or a `case`) after it replaces its status; {FIX} directly after it"
# A handler's last command that ends the run of the test (failing it, or leaving on purpose).
ENDS = {"false", "return", "exit", "skip", "fail", "flunk"}
# Inside `( )` only a failure counts: an exit, return or skip there leaves the subshell, not the
# test, so `|| (exit 0)` passes (#219 Codex); `exit <n>` counts for a literal n other than 0.
FAILS = {"false", "fail", "flunk"}
OPENERS = (("[[", "]]", "`[[ ]]`"), ("((", "))", "`(( ))`"))


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
    """What follows the `closer` matching the leading `opener`, or None when it is not closed.
    `((` counts every parenthesis, so `(( a + (b*c)))` closes at its last `))`."""
    if opener == "((":
        depth = 0
        for i, c in enumerate(bare):
            depth += {"(": 1, ")": -1}.get(c, 0)
            if depth == 0:
                return bare[i + 1:]
        return None
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


def _split_top(bare: str) -> list[tuple[str, str]]:
    """`bare` cut at the `;`, `&`, `&&` and `||` outside `{ }` and `( )`: (text, separator after
    it) pairs, the last one's separator "". `bare` has quotes and `$( )` blanked already. A `&`
    of a redirection (`>&2`, `&>f`) is no separator, nor an `&&`/`||` inside `[[ ]]`: those
    are the expression's (`[[ a == x || a == y ]]`)."""
    bare = CASE_BLOCK.sub(lambda m: CASE_MARK + " " * (len(m.group()) - 1), bare)
    parts: list[tuple[str, str]] = []
    depth, tests, start, i = 0, 0, 0, 0
    while i < len(bare):
        c = bare[i]
        if tests:
            # Inside `[[ ]]` only its close counts: `*{*` or `( a )` there is the expression's.
            if bare.startswith("]]", i) and bare[i - 1:i] in (" ", "\t"):
                tests -= 1
                i += 1
            i += 1
            continue
        if bare.startswith("[[", i) and bare[i - 1:i] in ("", " ", "\t", "(", "{", ";", "&", "|"):
            tests += 1
            i += 2
            continue
        if c in "({":
            depth += 1
        elif c in ")}":
            depth -= 1
        elif depth == 0 and bare.startswith(("&&", "||"), i):
            parts.append((bare[start:i], bare[i:i + 2]))
            start, i = i + 2, i + 2
            continue
        elif depth == 0 and (c == ";" or (
            c == "&" and bare[i - 1:i] not in (">", "<") and bare[i + 1:i + 2] != ">"
        )):
            parts.append((bare[start:i], c))
            start = i + 1
        i += 1
    parts.append((bare[start:], ""))
    return parts


def _pipeline_tail(command: str) -> str:
    """The last command of a pipeline (outside `{ }` and `( )`): the one its status is.
    `_split_top` has already cut at `||`, so every `|` left is a pipe."""
    depth, start = 0, 0
    for i, c in enumerate(command):
        depth += c in "({"
        depth -= c in ")}"
        if c == "|" and depth == 0 and command[i - 1:i] != ">":  # `>|` clobbers, no pipe
            start = i + 1
    return command[start:].removeprefix("&")  # `|&`


def _unredirected(command: str) -> str:
    """<command> stripped, without its trailing redirections (`{ ...; false; } >&2`)."""
    command = command.strip()
    while (stripped := TRAILING_REDIRECT.sub("", command)) != command and stripped:
        command = stripped.strip()
    return command


def _ends(handler: str) -> bool:
    """The handler's last command is one of ENDS: itself, or the last inside `{ }` or `( )`, and
    the last of a pipeline (`|| false | cat` is cat's status, 0), and one that always runs:
    in `{ true || false; }` the false never does (#219 Codex)."""
    if handler.strip().startswith("! "):
        return False  # `! cmd` negates its pipeline: `|| ! true | false` succeeds (#219 Codex)
    body = _unredirected(_pipeline_tail(handler))
    subshell = False
    while body[:1] in ("{", "(") and body[-1:] in ("}", ")"):
        subshell = subshell or body[0] == "("
        inner = [part for part in _split_top(body[1:-1]) if part[0].strip()]
        # `a && false` fails either way; `a || false` is a's success when a succeeds.
        # `{ false & }` backgrounds it: the group returns 0 at once (#219 Codex).
        if not inner or inner[-1][1] == "&" or (len(inner) > 1 and inner[-2][1] == "||"):
            return False
        if inner[-1][0].strip().startswith("! "):
            return False
        body = _unredirected(_pipeline_tail(inner[-1][0]))
    words = body.split()
    if not words:
        return False
    if subshell:
        return words[0] in FAILS or (
            # bash takes the status modulo 256: `exit 256` is 0.
            words[0] == "exit" and len(words) > 1 and words[1].isdigit()
            and int(words[1]) % 256 != 0
        )
    return words[0] in ENDS


def _assertion_end(parts: list[tuple[str, str]]) -> int:
    """The index of the assertion's last part: the tests an `&&` chain joins to it."""
    return next((i for i, (_, sep) in enumerate(parts) if sep != "&&"), len(parts) - 1)


def _piped(parts: list[tuple[str, str]], first: int) -> bool:
    """A pipe in the assertion's parts from <first> on, inside a group too: its tail is the
    status any handler sees (`[[ x ]] | cat || false`, `[ a ] && { [ b ] | cat; } || false`:
    #219 Codex). A redirection there (`>/dev/null`) changes nothing."""
    # A `case` there is not judged arm by arm: any arm's pipe could set its status (#219 Codex).
    return any(
        LONE_PIPE.search(TEST_EXPR.sub("", text)) or CASE_MARK in text
        for text, _ in parts[first:_assertion_end(parts) + 1]
    )


def _handled(parts: list[tuple[str, str]]) -> bool | None:
    """Whether the `||` after the assertion (and any `&& <test>` it joins: `[ a ] && [ b ] ||
    false`) hands its failure to handlers that all end the run; None when no `||` follows. Every
    handler of a chain must (`|| echo x || false` passes), and the last must end the list: in
    `|| false && x` the false is not the list's last command, so errexit ignores it, and
    `|| false &` backgrounds the list, which then returns 0 (#219 Codex)."""
    at = _assertion_end(parts)
    if parts[at][1] != "||":
        return None
    for text, sep in parts[at + 1:]:
        if not _ends(text) or sep in ("&&", "&"):
            return False
        if sep != "||":
            return True
    return True


def verdict(bare: str) -> tuple[str, bool] | None:
    """Why this statement's failure would go unseen, and whether appending `|| false` alone
    fixes it; None when it is seen. Only the first `;`-separated command is the assertion:
    `[[ x ]]; a || b` handles `a`, not the test."""
    weak = ("its `||` handler succeeds, or an `&&` follows it, so the failure is still unseen; "
            "end the statement with a handler ending in `false`")
    for opener, closer, shape in OPENERS:
        # `((` needs no blank after it (`((n == 2))`); `[[x` is no keyword (rollcall #83 Codex).
        if bare.startswith(opener) and (opener == "((" or bare[2:3] in ("", " ", "\t")):
            why = f"{shape} mid-test never fails on bash 3.2"
            rest = _after_close(bare, opener, closer)
            if rest is None:
                return f"{why}; {FIX}", False
            parts = _split_top(rest)
            if _piped(parts, 0):
                return f"{why}: {PIPED}", False
            handled = _handled(parts)
            if handled is None:
                return f"{why}; {FIX}", len(parts) == 1
            return None if handled else (f"{why}: {weak}", False)
    parts = _split_top(bare)
    if bare.startswith("! "):
        why = "`! cmd` never trips errexit"
        # `!` negates its whole pipeline, so only a later test's pipe replaces the status.
        if _piped(parts, 1):
            return f"{why}: {PIPED}", False
        handled = _handled(parts)
        if handled is None:
            return f"{why}; {FIX}", len(parts) == 1
        return None if handled else (f"{why}: {weak}", False)
    if re.match(r"(\[|test)\s", bare) and parts[0][1] == "&&":
        # `[ a ] && [ b ] || false` hands both to the handler; `[ c ] && action` may be a
        # conditional, not an assertion: `if` or split, by hand.
        handled = None if _piped(parts, 0) else _handled(parts)
        if handled:
            return None
        why = "a failing `[ ]` before `&&` never trips errexit"
        if handled is None:
            return f"{why}; one `[ ]` per line, or {FIX}", False
        return f"{why}: {weak}", False
    return None


def _open_group(statement: list[Line]) -> bool:
    """A handler group opened at a line's end (`|| {`) that the statement has not closed yet."""
    opened = next((m for line in statement if (m := OPENS_GROUP.search(line.bare))), None)
    if not opened:
        return False
    # Only the opener's own kind: a `case` arm's `a)` inside a `{ }` handler closes nothing.
    opener = opened.group().rstrip()[-1]
    closer = "}" if opener == "{" else ")"
    text = "".join(line.bare for line in statement)
    return text.count(opener) > text.count(closer)


def _statements(lines: list[Line]) -> list[list[Line]]:
    """Physical lines grouped into statements: a line ending in `&&`, `||`, `|` or `\\` takes
    the next one, unless that one was not read (it starts inside a quote or a heredoc); a
    handler group opened at a line's end (`|| {`) takes every line up to its close."""
    out: list[list[Line]] = []
    for line in lines:
        last = out[-1][-1] if out else None
        if out and _open_group(out[-1]):
            out[-1].append(line)
        elif last and last.bare.rstrip().endswith(CONTINUES) and line.number == last.number + 1:
            out[-1].append(line)  # even one all quoted, whose `bare` is blank: `  "$f"`
        elif line.bare.strip():
            out.append([line])
    return out


def _joined(statement: list[Line]) -> str:
    """The statement on one line: a continued line joins with a blank, a line of a handler
    group with `;`, as its newline separates commands."""
    text, previous = "", None
    for line in statement:
        if previous is not None:
            text += " " if previous.bare.rstrip().endswith(CONTINUES) else "; "
        text += line.bare.strip().rstrip("\\")
        previous = line
    return text


def check_text(text: str) -> list[Finding]:
    found: list[Finding] = []
    for statement in _statements(code_lines(text)):
        joined = _joined(statement)
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
