#!/usr/bin/env python3
"""Shared shell metrics collector: shellcheck findings, branches per function, dead functions,
and the cycles and fan of the `source` graph.

One line in scripts/ci/metrics.conf, run by devkit/bin/metrics_collect.sh, for example:
  shell-infra repo python3 -I devkit/metrics/shell.py --root . --scope infra \\
      --src '**/*.sh' --src '.githooks/*' --shellcheck --complexity --dead --cycles --fan \\
      --list-out build/metrics/shell-infra.findings.txt --out build/metrics/shell-infra.json

Files: every file under --root matching a --src glob (root-relative, `**` crosses directories;
default `**/*.sh` and `**/*.bash`), minus --exclude globs and these directories wherever they sit:
.git, node_modules, .claude (lane worktrees), build, .venv, plus the vendored kit (`devkit/` when
`.devkit-rev` is beside it: its scripts are devkit's metrics, not the repo's). No file matched is
exit 2 (size.py's rule: a conf that matches nothing measures nothing). Tests are measured too:
a shell test is shell code a lane maintains, and nothing names shell tests consistently.

Keys (docs/metrics-keys.md), each behind its flag; `<scope>` is `--scope`:
  --shellcheck  lint.<scope>.shellcheck_errors    shellcheck's `error` and `warning` comments,
                lint.<scope>.shellcheck_warnings  run as devkit/bin/shellcheck.sh runs it: the
                                                  pinned release (bin/release_tool.sh provides
                                                  it, else exit 2 naming it) over
                                                  lint/shellcheckrc plus the repo's .shellcheckrc.
                                                  `info` and `style` are not counted: they are
                                                  advice, and SC2086 alone would swamp the key.
                                                  The warnings also count devkit's own
                                                  `stdin-in-read-loop` (below).
  --complexity  complexity.<scope>.branches_max   decision points per function: `if`, `elif`,
                complexity.<scope>.branches_over_15  `case`, `for`, `while`, `until` in command
                                                  position and every `&&`/`||` (inside `[[ ]]`
                                                  too), counted in the innermost function. A
                                                  file's top level is one more unit, `<main>`:
                                                  a script's dispatch lives there. A `case` is
                                                  one branch however many arms, so an argument
                                                  parser does not read as complex. Not counted:
                                                  `&&`/`||` inside `(( ))`/`$(( ))`, and guards
                                                  (below).
  --dead        dead.<scope>.unused               functions defined in the set whose name
                                                  appears nowhere in the set's code outside
                                                  their own body (comments blanked; strings,
                                                  heredocs, `trap fn EXIT` and `"$fn"` count as
                                                  uses, so it errs towards alive). Not seen: a
                                                  caller outside the set (a Makefile recipe) and
                                                  a name built at run time (`cmd_$1`).
                                                  The plan hooks bin/local_gate.sh calls
                                                  (gate_plan, gate_plan_extra, gate_cleanup)
                                                  are entry points, never dead, and so is each
                                                  `--entry NAME` (repeatable), the repo's
                                                  declaration in metrics.conf of a function
                                                  whose callers are outside the set (another
                                                  repo, a generated copy, the tests); one that
                                                  names no function in the set is exit 2.
  --cycles      coupling.<scope>.cycles           files that source each other: strongly
                                                  connected components of the `source` graph
                                                  (more than one file, or a file sourcing
                                                  itself), python.py's Tarjan
  --fan         coupling.<scope>.fan_in_max       over the same graph, python.py's definition:
                coupling.<scope>.fan_out_max      how many files source a file, how many it
                                                  sources (fan_in_max is report-only)

Guards (--complexity, decisions.md 2026-10-27): a branch whose taken side leaves and which has
no other side is not counted, so a flat list of refusals reads as the straight line it is. Two
spellings, scored alike: an and-or list ending `&& X`/`|| X`, and an `if` with no `elif`/`else`,
where X (or the if body, or a `{ }` right side) ends with `exit`, `return`, `continue`, `break`
or a call to a function of the set whose body ends in `exit` (`die`, `usage() { die …; }`; the
name resolves in the guard's file first, and every definition must exit). Still counted: a
guard whose side goes on (`|| fail "…"` that sets rc=1, `|| x && y`, `|| exit &`), one whose
side ends in a nested compound (`fi`, `}`), and `exec` (`exec 3>&1` returns). A die defined
outside the set (a vendored library) is not known, so its guards count.

The `source` graph: files are nodes; `source X` or `. X` in command position is an edge to the
measured file X names. X is resolved lexically, never run. A `# shellcheck source=<path>` on the
comment lines right above names it first (root-relative, then beside the file); `/dev/null`
(shellcheck told not to follow) falls through to the argument, since the file is still
sourced. Otherwise the argument, quotes dropped, keeps its literal tail after the last expansion:
`"$(dirname "${BASH_SOURCE[0]}")/_lib.sh"`, `"$HERE/_lib.sh"` and `${DIR}/_lib.sh` all read `/_lib.sh`, looked up beside the sourcing file, then at the root. A literal path is
looked up at the root, then beside the file. An argument with no `/…` literal tail (`. "$1"`,
`"$dir/$name.sh"`) or a target outside the measured set (the vendored devkit/, a system file)
is no edge. Blind spots: a path built at run time, and bats' `load`.

stdin-in-read-loop (with --shellcheck): a command that reads its stdin, inside the body of a
`while`/`until` loop whose condition is `read` (no `-u`), with its stdin neither redirected
(`<`, `<<`, `<<<`, `<&`, `0<`) nor piped in. The loop's input is its stdin too, so the command
drains it and the loop ends after one pass: homelab #108's pihole import inserted only the first
adlist. The readers: `ssh` without `-n`/`-f`, `docker exec|run` and `kubectl exec` with `-i`, and
`ffmpeg` without `-nostdin`. Why devkit's own (2026-10-19): shellcheck 0.11.0 drops SC2095
whenever the line carries any `disable` directive, and SC2029 forces one on most ssh lines; it
also misses `read … || [ -n … ]` conditions. It honours no disable comment: the fix is the flag
or the redirect.

The function scanner is lexical and stdlib-only: it tracks quotes, `$(...)`, `${...}`,
backticks, heredocs, `[[ ]]`, `case` patterns and `{ }`/`( )` nesting, which is what finding a
function's body and its command-position keywords needs. A file it cannot balance (an unclosed
quote, brace or heredoc it misreads) is exit 2 naming <path>:<line>, never a guessed number.

--list-out FILE: python.py's format (`# <key>` then one line per finding, keys sorted; empty
when there are none). Paths are --root joined with the root-relative path.
  shellcheck_errors, shellcheck_warnings   <path>:<line> SC<code> <message>, or <path>:<line>
                                           stdin-in-read-loop <message>, by path and line
  branches_over_15                         <path>:<line> <function> branches=<n>, worst first
  unused                                   <path>:<line> <function> function, by path and line
  cycles                                   one line per cycle: its files, space-separated, largest first
  fan_in_max, fan_out_max                  <path> fan_in=<n> | fan_out=<n>, the top 10 (python.py's)

Deterministic. Output: a flat JSON object to --out (default stdout). Exit: 0 ok, 2 a missing
tool, a shellcheck that failed to run, a file the scanner cannot balance or a bad call.
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

EXIT_USAGE = 2
BRANCHES_THRESHOLD = 15
DEFAULT_SRC = ("**/*.sh", "**/*.bash")
SKIP_DIRS = frozenset({".git", "node_modules", ".claude", "build", ".venv"})
SCOPE = re.compile(r"[A-Za-z0-9_-]+")  # the key's middle segment: no dots, no whitespace
SHELLCHECK = Path(__file__).resolve().parent.parent / "bin" / "shellcheck.sh"
COUNTED_LEVELS = {"error": "shellcheck_errors", "warning": "shellcheck_warnings"}
MAIN = "<main>"
# The functions a repo defines for devkit to call (bin/local_gate.sh's plan contract): alive
# though nothing in the repo names them.
ENTRY_POINTS = frozenset({"gate_plan", "gate_plan_extra", "gate_cleanup"})
# A guard's taken side ends in one of these, or in a function whose body ends in `exit`. Not
# `exec`: `exec 3>&1` returns.
GUARD_EXITS = frozenset({"exit", "return", "continue", "break"})
# After these an and-or list goes on, so the command before them is no guard's last.
CHAINS = frozenset({"&&", "||", "|", "|&", "&"})
# A command before or after these runs in a child process: its exit leaves only the child.
ASIDE = frozenset({"|", "|&", "&"})
# After these the list goes on: the next command runs on a condition or in a child.
CONTINUED = frozenset({"&&", "||", "|", "|&"})
# Words before a command that leave it the command (assignments too, `X=y cmd`).
PREFIXES = frozenset({"!", "time"})

# Words that are never a body's tail: the reserved words that only open a part of a compound
# command, and the closers, which make themselves the enclosing body's tail when they pop.
NOT_TAILS = frozenset({"then", "else", "elif", "do", "!", "time", "fi", "}", "esac"})

BRANCH_WORDS = frozenset({"case", "for", "while", "until"})  # and if/elif, in IF_WORDS
IF_WORDS = frozenset({"if", "then", "elif", "else", "fi"})

# Reserved words after which the next word is again a command.
COMMAND_WORDS = frozenset({"then", "else", "do", "!", "time", "if", "elif", "while", "until"})
# A function name as bash accepts it in practice; also how a use is recognised in the code.
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_:.-]*")
# Longest first, so `;;&` is not read as `;;` then `&`.
OPERATORS = (";;&", ";;", ";&", "&&", "||", "|&", "<<<", "<<-", "<<", "&>>", "&>", ">>", ">&", "<&",
             "<>", ">|", ";", "&", "|", "(", ")", "<", ">")  # fmt: skip
WORD_END = frozenset(" \t\n;&|()<>")
# A word that assigns (`IFS=`, `a[0]+=x`) before a command: it keeps command position.
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=")
STDIN_REDIRECTS = frozenset({"<", "<<", "<<-", "<<<", "<&", "<>"})
OUTPUT_REDIRECTS = frozenset({">", ">>", ">|", ">&", "&>", "&>>"})
# The redirects whose next word is their target (a heredoc's delimiter is read with its body).
TARGETED = (STDIN_REDIRECTS | OUTPUT_REDIRECTS) - {"<<", "<<-"}
UNIT_FLAG = re.compile(r"-[a-zA-Z]*u.*")  # read -u <fd>, or -ru3
SSH_ARG_FLAGS = frozenset("BbcDEeFIiJLlmOoPpQRSWw")  # ssh options that take a value
STDIN_CHECK = "stdin-in-read-loop"


class CollectorError(Exception):
    """A missing tool, a failed shellcheck, an unbalanced file or a bad call (exit 2)."""


@dataclass
class Collected:
    keys: dict[str, int] = field(default_factory=dict)
    findings: dict[str, list[str]] = field(default_factory=dict)


@dataclass
class Function:
    name: str
    line: int
    start: int  # offset of the name: the body span [start, end) holds the definition
    end: int = -1
    branches: int = 0  # every decision point; complexity() discounts the guards
    guards: list[str] = field(default_factory=list)  # each guard's last command word
    tail: str = ""  # the body's last unconditional command word ("" for a subshell body)
    returns: bool = False  # a `return` anywhere in the body: it may come back before its tail



@dataclass
class Frame:
    kind: str  # brace, paren, case, if; fn-brace / fn-paren close a function
    state: str = ""  # a case's head | pattern | body; an if's cond | body | else
    tail: str = ""  # the last command word directly inside; "" when it is conditional or a child's

    guard: bool = False  # a `{ }` that is the right side of `&&`/`||`


@dataclass
class Loop:
    """A `while`/`until`/`for`/`select` loop the scanner is inside (stdin-in-read-loop)."""

    state: str  # cond (while/until), head (for/select), body (after `do`)
    reads: bool = False  # the condition's first command is `read` without -u
    cond_seen: bool = False


@dataclass
class Command:
    """One simple command's words, for the stdin-in-read-loop check."""

    word: str
    line: int
    in_loop: bool  # inside the body of a loop that reads stdin
    piped: bool  # the stdin is a pipe: `x | ssh …`
    args: list[str] = field(default_factory=list)
    redirected: bool = False
    loop: Loop | None = None  # set for the `read` that is a loop's condition


@dataclass
class Context:
    """One code_until's parse state: each `$(...)` gets its own, as bash parses it apart."""

    frames: list[Frame] = field(default_factory=list)
    cmd: bool = True  # the next word is in command position
    dbl: bool = False  # inside [[ ]]
    last: str = ""  # the previous token (`for ((` is arithmetic)
    pending_fn: Function | None = None  # `name()` read, its body not yet opened
    sourcing: bool = False  # `source`/`.` read: the next word is the file it sources
    command: Command | None = None  # the simple command being read
    assigned: bool = False  # an assignment word opened this command: the next word is its name
    guard: str | None = None  # an and-or right side's last word, until its list is known to end
    # The command being read runs on a condition or in a child (after &&, ||, |), so it is no
    # tail. Held over prefixes (`a && X=y exit`, `a && ! exit`) until the list ends.
    conditional: bool = False
    # Right after `&&`/`||`: the next command is the list's right side. Held over prefixes.
    operand: bool = False

    def case(self) -> Frame | None:
        return self.frames[-1] if self.frames and self.frames[-1].kind == "case" else None


@dataclass(frozen=True)
class Source:
    arg: str  # the argument as written, quotes and all
    line: int


@dataclass
class Scanned:
    shown: str
    code: str  # the text with comments blanked, offsets preserved
    units: list[Function]  # the functions, then the file's top level as MAIN
    sources: list[Source]  # every `source`/`.` in command position, in file order
    stdin_readers: list[tuple[int, str]]  # (line, message): stdin-in-read-loop findings


# ----------------------------------------------------------------------------- scanner


class Scanner:
    """One file's functions and their branch counts, read lexically (module docstring)."""

    def __init__(self, text: str, shown: str) -> None:
        self.s, self.n, self.i, self.line, self.shown = text, len(text), 0, 1, shown
        self.main = Function(MAIN, 1, 0, len(text))
        self.functions: list[Function] = []
        self.open: list[Function] = []
        self.comments: list[tuple[int, int]] = []
        self.heredocs: list[tuple[str, bool, int]] = []  # pending (delimiter, strip tabs, line)
        self.sources: list[Source] = []
        self.loops: list[Loop] = []
        self.stdin_readers: list[tuple[int, str]] = []

    def fail(self, what: str, line: int | None = None) -> CollectorError:
        return CollectorError(f"{self.shown}:{line or self.line}: {what}")

    def scan(self) -> Scanned:
        self.code_until(None)
        chars = list(self.s)
        for a, b in self.comments:
            chars[a:b] = " " * (b - a)
        return Scanned(self.shown, "".join(chars), [*self.functions, self.main], self.sources, self.stdin_readers)

    def unit(self) -> Function:
        """The innermost function open here, else the file's top level."""
        return self.open[-1] if self.open else self.main


    def peek(self, k: int = 0) -> str:
        return self.s[self.i + k] if self.i + k < self.n else ""

    def skip_blanks(self) -> None:
        while self.peek() in (" ", "\t") and self.peek():
            self.i += 1

    def newline(self) -> None:
        self.i += 1
        self.line += 1
        self.read_heredocs()

    # -- code ---------------------------------------------------------------------------

    def code_until(self, closer: str | None) -> None:
        """Scan commands until EOF (closer None) or the `)` that ends a `$(` / `<(`."""
        ctx = Context()
        start_line = self.line
        while self.i < self.n:
            c = self.peek()
            if c in (" ", "\t"):
                self.i += 1
            elif c == "\\" and self.peek(1) == "\n":
                self.i += 1
                self.newline()
            elif c == "\n":
                self.end_command(ctx)
                self.newline()
                ctx.cmd = True
                if ctx.last not in CONTINUED:  # `a ||⏎ b`: the list goes on over the newline
                    ctx.conditional = ctx.operand = False

            elif c == "#":  # only at a token boundary: a word consumes its own `#`
                start = self.i
                while self.i < self.n and self.peek() != "\n":
                    self.i += 1
                self.comments.append((start, self.i))
            elif c in "<>" and self.peek(1) == "(":
                self.i += 2
                self.code_until(")")
                ctx.cmd, ctx.last = False, "<(...)"
            elif c == "(" and self.peek(1) == "(" and (ctx.cmd or ctx.last in ("for", "select")) and not ctx.dbl:
                self.i += 2
                self.balanced(")", depth=2)
                ctx.cmd, ctx.last = False, "((...))"
            elif c in "|&;()<>":
                op = next(o for o in OPERATORS if self.s.startswith(o, self.i))
                self.i += len(op)
                if op in TARGETED and not ctx.dbl:
                    self.redirect_target(ctx, op)
                    continue
                if self.operator(ctx, op, closer):
                    return
                ctx.last = op
            else:
                start, line = self.i, self.line
                word = self.word()
                self.on_word(ctx, word, start, line)
                ctx.last = word
        self.end_command(ctx)
        if closer is not None:
            raise self.fail("`$(` or `<(` never closed", start_line)
        if ctx.frames or ctx.pending_fn is not None:
            what = ctx.frames[-1].kind if ctx.frames else "function body"
            raise self.fail(f"unclosed {what} at end of file")

    def operator(self, ctx: Context, op: str, closer: str | None) -> bool:
        """Apply one operator; True when it is the `)` that ends this code_until."""
        if op in CHAINS:
            ctx.guard = None  # `a || b && c`, `a || b | c`, `a || b &`: b is no guard's last
        if op in ASIDE and ctx.frames:
            ctx.frames[-1].tail = ""  # `exit 1 &`, `exit 1 | cat`: the exit is a child's
        ctx.operand = op in ("&&", "||")
        if op in CONTINUED:
            ctx.conditional = True
        elif op in (";", "&", ";;", ";&", ";;&"):
            ctx.conditional = False
        if op in STDIN_REDIRECTS:
            self.redirect(ctx, op)
        elif op not in OUTPUT_REDIRECTS:
            self.end_command(ctx)

        case = ctx.case()
        if case is not None and case.state == "pattern" and not ctx.dbl and op in ("(", "|", ")"):
            if op == ")":  # a pattern's optional leading paren and its alternation are no-ops
                case.state, ctx.cmd = "body", True
        elif op in ("&&", "||"):
            self.unit().branches += 1
            ctx.cmd = True
        elif ctx.dbl and op in ("(", ")", "<", ">"):
            pass  # grouping and string comparison inside [[ ]]
        elif op in (";;", ";&", ";;&"):
            if case is None or case.state != "body":
                raise self.fail(f"`{op}` outside a case arm")
            case.state, ctx.cmd = "pattern", False
        elif op == "(":
            kind = "paren" if ctx.pending_fn is None else "fn-paren"
            self.push(ctx, kind)
            ctx.cmd = True
        elif op == ")":
            if ctx.frames and ctx.frames[-1].kind in ("paren", "fn-paren"):
                self.pop(ctx, op)
            elif not ctx.frames and closer == ")":
                return True
            else:
                raise self.fail("unbalanced `)`")
        elif op in ("<<", "<<-"):
            self.skip_blanks()
            delim = self.word()
            self.heredocs.append((re.sub(r"[\"'\\]", "", delim), op == "<<-", self.line))
        elif op in (";", "&", "|", "|&"):
            ctx.cmd = True
        return False

    def redirect_target(self, ctx: Context, op: str) -> None:
        """A redirect and its target word, which is never a command word: `a || >&2 die x`
        keeps die the right side's command. The parse state is left as it was."""
        if op in STDIN_REDIRECTS:
            self.redirect(ctx, op)
        self.skip_blanks()
        self.word()

    def on_word(self, ctx: Context, word: str, start: int, line: int) -> None:
        case = ctx.case()
        if ctx.dbl:
            ctx.dbl = word != "]]"
        elif case is not None and case.state in ("head", "pattern"):
            if case.state == "head" and word == "in":
                case.state = "pattern"
            elif case.state == "pattern" and word == "esac":
                self.pop(ctx, word)
        elif ctx.sourcing and not ctx.cmd:
            self.sources.append(Source(word, line))
            ctx.sourcing = False
        elif not ctx.cmd:
            if ctx.command is not None:
                ctx.command.args.append(word)
        elif ctx.pending_fn is not None:
            if word != "{":
                raise self.fail(f"function {ctx.pending_fn.name}: a body other than {{ }} or ( )", line)
            self.push(ctx, "fn-brace")
        else:
            self.command_word(ctx, word, start, line)

    def command_word(self, ctx: Context, word: str, start: int, line: int) -> None:
        """A word in command position: a reserved word, a function definition or a command."""
        ctx.sourcing = False  # a `.` with no argument before the next command sources nothing
        operand = ctx.operand
        if word not in NOT_TAILS and ctx.frames:
            ctx.frames[-1].tail = "" if ctx.conditional else word
        if ASSIGNMENT.match(word) and ctx.pending_fn is None:
            ctx.assigned = True  # `IFS= read …`: the command is the next word
            return
        if word not in PREFIXES:
            ctx.operand = False
        if ctx.assigned:  # bash reads no reserved word after an assignment: `a=1 if` runs `if`
            self.simple_command(ctx, word, line, operand=operand)
            return
        self.track_loop(word)
        if word == "function":
            self.skip_blanks()
            name_start, name_line = self.i, self.line
            name = self.word()
            self.empty_parens()
            ctx.pending_fn = Function(name, name_line, name_start)
        elif word in IF_WORDS:
            self.if_word(ctx, word, line)
        elif word in BRANCH_WORDS:
            self.unit().branches += 1
            if word == "case":
                ctx.frames.append(Frame("case", "head"))
            ctx.cmd = word not in ("case", "for")
        elif word in COMMAND_WORDS:
            pass
        elif word == "{":
            self.push(ctx, "brace")
            ctx.frames[-1].guard = operand
        elif word == "}":
            if not ctx.frames or ctx.frames[-1].kind not in ("brace", "fn-brace"):
                raise self.fail("unbalanced `}`", line)
            self.pop(ctx, word)
        elif word == "esac" and ctx.case() is not None:
            self.pop(ctx, word)
        elif word == "[[":
            ctx.dbl, ctx.cmd = True, False
        elif word in ("source", "."):
            ctx.sourcing, ctx.cmd = True, False
        elif self.empty_parens():
            ctx.pending_fn = Function(word, line, start)
        else:
            self.simple_command(ctx, word, line, operand=operand)

    def simple_command(self, ctx: Context, word: str, line: int, *, operand: bool) -> None:
        """`word` is the command of a simple command; an and-or right side's is a guard's."""
        ctx.cmd = False
        if operand:
            ctx.guard = word
        if word == "return":
            self.unit().returns = True
        self.begin_command(ctx, word, line)

    def if_word(self, ctx: Context, word: str, line: int) -> None:
        """`if` opens a frame (cond, then body after `then`); `fi` closes it, a guard's when the
        body was its only side; `elif` and `else` add a side, so it is no guard."""
        if word == "if":
            self.unit().branches += 1
            ctx.frames.append(Frame("if", "cond"))
            return
        if not ctx.frames or ctx.frames[-1].kind != "if":
            raise self.fail(f"`{word}` outside an if", line)
        frame = ctx.frames[-1]
        if word == "fi":
            if frame.state == "body" and frame.tail:
                self.unit().guards.append(frame.tail)
            self.pop(ctx, word)
        elif word == "then" and frame.state == "cond":
            frame.state = "body"
        elif word == "elif":
            frame.state = "else"
            self.unit().branches += 1
        else:  # `else`, or the `then` after an elif
            frame.state = "else"


    # -- stdin-in-read-loop -------------------------------------------------------------

    def track_loop(self, word: str) -> None:
        """Keep the loop stack: `while`/`until` open a condition, `do` a body, `done` closes."""
        top = self.loops[-1] if self.loops else None
        if word in ("while", "until"):
            self.loops.append(Loop("cond"))
        elif word in ("for", "select"):
            self.loops.append(Loop("head"))
        elif word == "do" and top is not None and top.state != "body":
            top.state = "body"
        elif word == "done" and top is not None:
            self.loops.pop()

    def begin_command(self, ctx: Context, word: str, line: int) -> None:
        top = self.loops[-1] if self.loops else None
        cond = top if top is not None and top.state == "cond" and not top.cond_seen else None
        if cond is not None:
            cond.cond_seen = True
            cond.reads = word == "read"
        ctx.command = Command(
            word, line, in_loop=any(lp.reads and lp.state == "body" for lp in self.loops),
            piped=ctx.last in ("|", "|&"), loop=cond if word == "read" else None,
        )  # fmt: skip

    def redirect(self, ctx: Context, op: str) -> None:
        """A `<`-family redirect: the command's stdin, unless a digit other than 0 prefixes it."""
        command = ctx.command
        if command is None:
            return
        at = self.i - len(op) - 1
        if at >= 0 and self.s[at].isdigit() and command.args and command.args[-1].isdigit():
            if command.args.pop() != "0":
                return
        command.redirected = True

    def end_command(self, ctx: Context) -> None:
        if ctx.guard is not None:  # the and-or list ended with the guard's side
            self.unit().guards.append(ctx.guard)
            ctx.guard = None
        command, ctx.command, ctx.assigned = ctx.command, None, False
        if command is None:
            return
        if command.loop is not None and any(UNIT_FLAG.fullmatch(a) for a in command.args):
            command.loop.reads = False  # `read -u 3`: the loop reads fd 3, not stdin
        if command.in_loop and not command.piped and not command.redirected:
            message = stdin_reader(command.word, command.args)
            if message is not None:
                self.stdin_readers.append((command.line, message))

    def push(self, ctx: Context, kind: str) -> None:
        """Open a `{`/`(` frame; a pending definition's opens the function's body."""
        ctx.frames.append(Frame(kind))
        ctx.conditional = False  # inside, a command is unconditional relative to the frame

        if ctx.pending_fn is not None:
            self.functions.append(ctx.pending_fn)
            self.open.append(ctx.pending_fn)
            ctx.pending_fn = None
        ctx.cmd = True

    def pop(self, ctx: Context, closer: str) -> None:
        """Close the innermost frame; `closer` becomes the enclosing frame's tail."""
        frame = ctx.frames.pop()
        if frame.kind.startswith("fn-"):
            fn = self.open.pop()
            fn.end = self.i
            fn.tail = frame.tail if frame.kind == "fn-brace" else ""  # a subshell's exit returns
        if frame.guard and frame.tail:
            ctx.guard = frame.tail
        if ctx.frames:
            ctx.frames[-1].tail = closer
        ctx.cmd = False

    def empty_parens(self) -> bool:
        """Consume `( )` after a function name; False (nothing consumed) when it is not there."""
        j = self.i
        while j < self.n and self.s[j] in " \t":
            j += 1
        if j >= self.n or self.s[j] != "(":
            return False
        j += 1
        while j < self.n and self.s[j] in " \t":
            j += 1
        if j >= self.n or self.s[j] != ")":
            return False
        self.i = j + 1
        return True

    # -- words --------------------------------------------------------------------------

    def word(self) -> str:
        """One word, quotes and expansions inside it consumed; the raw text."""
        start = self.i
        while self.i < self.n:
            c = self.peek()
            if c in WORD_END:
                text = self.s[start : self.i]
                # `a=(x y)` and extglob `@(a|b)`: the paren belongs to the word.
                if c == "(" and (text.endswith("=") or (text and text[-1] in "@!+*?")):
                    self.i += 1
                    self.balanced(")", depth=1)
                    continue
                break
            self.quoted_or_char()
        return self.s[start : self.i]

    def quoted_or_char(self) -> None:
        """Consume one character, or one whole quote or expansion starting here."""
        c, line = self.peek(), self.line
        if c == "\\":
            self.i += 1
            if self.peek() == "\n":
                self.line += 1
            self.i += 1
        elif c == "'":
            end = self.s.find("'", self.i + 1)
            if end < 0:
                raise self.fail("unclosed single quote", line)
            self.line += self.s.count("\n", self.i, end)
            self.i = end + 1
        elif c == "$" and self.peek(1) == "'":
            self.i += 2
            self.until_quote("'", line, expansions=False)
        elif c == '"':
            self.i += 1
            self.until_quote('"', line, expansions=True)
        elif c == "`":
            self.i += 1
            self.until_quote("`", line, expansions=False)
        elif c == "$" and self.peek(1) == "(" and self.peek(2) == "(":
            self.i += 3
            self.balanced(")", depth=2)
        elif c == "$" and self.peek(1) == "(":
            self.i += 2
            self.code_until(")")
        elif c == "$" and self.peek(1) == "{":
            self.i += 2
            self.balanced("}", depth=1)
        else:
            if c == "\n":
                self.line += 1
            self.i += 1

    def until_quote(self, quote: str, line: int, *, expansions: bool) -> None:
        while self.i < self.n:
            c = self.peek()
            if c == quote:
                self.i += 1
                return
            if c == "\\":
                self.i += 1
                if self.peek() == "\n":
                    self.line += 1
                self.i += 1
            elif expansions and c in "$`":
                self.quoted_or_char()
            else:
                if c == "\n":
                    self.line += 1
                self.i += 1
        raise self.fail(f"unclosed {quote}", line)

    def balanced(self, close: str, depth: int) -> None:
        """Consume to the `close` that brings depth to 0: `${...}`, `$((...))`, `a=(...)`."""
        open_ = "{" if close == "}" else "("
        line = self.line
        while self.i < self.n:
            c = self.peek()
            if c == close:
                depth -= 1
                self.i += 1
                if depth == 0:
                    return
            elif c == open_:
                depth += 1
                self.i += 1
            elif c in "\\'\"`$":
                self.quoted_or_char()
            else:
                if c == "\n":
                    self.line += 1
                self.i += 1
        raise self.fail(f"unclosed `{open_}`", line)

    def read_heredocs(self) -> None:
        while self.heredocs:
            delim, strip, line = self.heredocs.pop(0)
            while True:
                if self.i >= self.n:
                    raise self.fail(f"heredoc {delim} never ends", line)
                end = self.s.find("\n", self.i)
                end = self.n if end < 0 else end
                text = self.s[self.i : end]
                self.i = min(end + 1, self.n)
                self.line += 1
                if (text.lstrip("\t") if strip else text) == delim:
                    break


def _short_flags(args: list[str], takes_value: frozenset[str]) -> set[str]:
    """The single-letter options before the first operand (`ssh -nT -i key host cmd` -> n T i)."""
    seen: set[str] = set()
    it = iter(args)
    for arg in it:
        if not arg.startswith("-") or arg == "-" or arg.startswith("--"):
            if arg.startswith("--"):
                seen.add(arg)
                continue
            break
        for k, letter in enumerate(arg[1:]):
            seen.add(letter)
            if letter in takes_value:
                if k == len(arg) - 2:
                    next(it, None)
                break
    return seen


def stdin_reader(word: str, args: list[str]) -> str | None:
    """Why this command reads its stdin, or None (module docstring: stdin-in-read-loop)."""
    tool = posixpath.basename(word)
    if tool == "ssh":
        flags = _short_flags(args, SSH_ARG_FLAGS)
        return None if {"n", "f"} & flags else "ssh reads the loop's stdin; add -n or </dev/null"
    if tool in ("docker", "kubectl") and args[:1] == ["exec"] or (tool == "docker" and args[:1] == ["run"]):
        flags = _short_flags(args[1:], frozenset())
        if "i" in flags or "--interactive" in flags:
            return f"{tool} {args[0]} -i reads the loop's stdin; drop -i or add </dev/null"
        return None
    if tool == "ffmpeg" and "-nostdin" not in args:
        return "ffmpeg reads the loop's stdin; add -nostdin or </dev/null"
    return None


# ------------------------------------------------------------------------------- files


def source_files(root: Path, srcs: list[str], excludes: list[str]) -> list[Path]:
    """Root-relative paths of the measured set, sorted (module docstring)."""
    vendored = (root / ".devkit-rev").is_file()
    found: set[Path] = set()
    for pattern in srcs:
        for p in root.glob(pattern):
            rel = p.relative_to(root)
            if not p.is_file() or SKIP_DIRS.intersection(rel.parts[:-1]):
                continue
            if vendored and rel.parts[0] == "devkit":
                continue
            if any(fnmatch.fnmatch(rel.as_posix(), g) for g in excludes):
                continue
            found.add(rel)
    if not found:
        raise CollectorError(f"no file under {root} matches --src {' '.join(srcs)}")
    return sorted(found)


def shown(root: Path, rel: str) -> str:
    """A root-relative path as a lane opens it (repo-relative in a gate run)."""
    return (root / rel).as_posix()


def scan_files(root: Path, files: list[Path]) -> list[Scanned]:
    scanned = []
    for rel in files:
        try:
            text = (root / rel).read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise CollectorError(f"{shown(root, rel.as_posix())}: not UTF-8 text ({exc})") from exc
        scanned.append(Scanner(text, shown(root, rel.as_posix())).scan())
    return scanned


# ------------------------------------------------------------------------------ keys


class Leaves:
    """Which guard words leave: GUARD_EXITS, or a call to a function whose body ends in `exit`
    (directly or through another such function: `usage() { die …; }`) and holds no `return`
    (metrics_collect's `refuse_missing` returns when nothing is missing).


    A name resolves to its definitions in the guard's own file, else to every definition in the
    set, and leaves only when all of them do: `fail() { …; rc=1; }` and `die() { …; exit 2; }`
    share names across devkit's scripts. Least fixed point, so mutual recursion never leaves.
    """

    def __init__(self, scanned: list[Scanned]) -> None:
        self.tails: list[tuple[str, str]] = []  # (file, tail) per definition
        self.local: dict[str, dict[str, list[int]]] = {s.shown: {} for s in scanned}
        self.anywhere: dict[str, list[int]] = {}
        for s in scanned:
            for f in s.units:
                if f.name != MAIN:
                    self.local[s.shown].setdefault(f.name, []).append(len(self.tails))
                    self.anywhere.setdefault(f.name, []).append(len(self.tails))
                    # A body that may return before its tail never leaves for sure.
                    self.tails.append((s.shown, "" if f.returns else f.tail))
        self.exits = [False] * len(self.tails)
        changed = True
        while changed:
            changed = False
            for i, (path, tail) in enumerate(self.tails):
                if not self.exits[i] and (tail == "exit" or self.calls_exit(tail, path)):
                    self.exits[i] = changed = True

    def calls_exit(self, word: str, path: str) -> bool:
        ids = self.local[path].get(word) or self.anywhere.get(word, [])
        return bool(ids) and all(self.exits[i] for i in ids)

    def __call__(self, word: str, path: str) -> bool:
        return word in GUARD_EXITS or self.calls_exit(word, path)


def counted_branches(scanned: list[Scanned]) -> list[tuple[Function, str, int]]:
    """(unit, path, its branches less its guards) for every unit (module docstring: Guards)."""
    leaves = Leaves(scanned)
    return [
        (f, s.shown, f.branches - sum(leaves(word, s.shown) for word in f.guards))
        for s in scanned for f in s.units
    ]  # fmt: skip


def complexity(scanned: list[Scanned], scope: str) -> Collected:
    units = counted_branches(scanned)
    over = sorted(

        (u for u in units if u[2] > BRANCHES_THRESHOLD), key=lambda u: (-u[2], u[1], u[0].line)
    )
    key = f"complexity.{scope}.branches_over_{BRANCHES_THRESHOLD}"
    return Collected(
        keys={f"complexity.{scope}.branches_max": max((n for _, _, n in units), default=0),
              key: len(over)},
        findings={key: [f"{path}:{f.line} {f.name} branches={n}" for f, path, n in over]},
    )  # fmt: skip


def dead(scanned: list[Scanned], scope: str, entries: frozenset[str]) -> Collected:
    """A function is used when its name appears in the set's code outside its own body."""
    defined = {f.name for s in scanned for f in s.units if f.name != MAIN}
    stale = sorted(entries - defined)
    if stale:
        raise CollectorError(f"--entry {' '.join(stale)}: no function of that name in the set")
    uses: dict[str, list[tuple[str, int]]] = {name: [] for name in defined}
    for s in scanned:
        for m in NAME.finditer(s.code):
            if m.group() in uses:
                uses[m.group()].append((s.shown, m.start()))
    unused = []
    for s in scanned:
        for f in s.units:
            if f.name == MAIN or f.name in ENTRY_POINTS or f.name in entries:
                continue
            outside = [u for u in uses[f.name] if u[0] != s.shown or not f.start <= u[1] < f.end]
            if not outside:
                unused.append((s.shown, f.line, f.name))
    key = f"dead.{scope}.unused"
    return Collected(
        keys={key: len(unused)},
        findings={key: [f"{p}:{line} {name} function" for p, line, name in sorted(unused)]},
    )


# A shellcheck directive naming the file the next command sources.
SOURCE_DIRECTIVE = re.compile(r"#\s*shellcheck\s+(?:[a-z-]+=\S+\s+)*source=(\S+)")
# The last expansion in an argument: what follows it is the literal tail.
LAST_EXPANSION = re.compile(r"\$(?:[A-Za-z_][A-Za-z0-9_]*|[0-9@#?*!$-])(?!.*[$)}])|[)}](?!.*[$)}])")


def _python() -> ModuleType:
    """metrics/python.py, for coupling_keys (`python3 -I` keeps this directory off sys.path)."""
    name = "devkit_metrics_python"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "python.py")
        if spec is None or spec.loader is None:
            raise CollectorError("cannot load metrics/python.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # before exec: dataclasses look their module up
        sys.dont_write_bytecode = True  # a consumer's vendored devkit/ stays byte-identical
        spec.loader.exec_module(module)
    return sys.modules[name]


def directive_above(lines: list[str], line: int) -> str | None:
    """The `# shellcheck source=` path on the comment lines right above `line` (1-based)."""
    i = line - 2
    while i >= 0 and lines[i].lstrip().startswith("#"):
        m = SOURCE_DIRECTIVE.search(lines[i])
        if m:
            return m.group(1)
        i -= 1
    return None


def source_candidates(arg: str, here: str, directive: str | None) -> list[str]:
    """Root-relative paths `source <arg>` may name, most likely first (module docstring)."""
    if directive is not None and directive != "/dev/null":
        return [directive, posixpath.join(here, directive)]
    text = arg.replace('"', "").replace("'", "")
    m = None
    for m in LAST_EXPANSION.finditer(text):
        pass
    tail = text[m.end():] if m else text
    # After an expansion only a `/…` tail is a path: `$name.sh` builds the file name at run time.
    if not tail or "$" in tail or "`" in tail or (m and not tail.startswith("/")):
        return []
    if m:
        rel = tail.lstrip("/")
        return [posixpath.join(here, rel), rel]
    return [tail, posixpath.join(here, tail)]


def source_graph(root: Path, scanned: list[Scanned], files: list[Path]) -> dict[str, set[str]]:
    """Shown path -> the measured files it sources."""
    by_rel = {posixpath.normpath(f.as_posix()): shown(root, f.as_posix()) for f in files}
    graph: dict[str, set[str]] = {s.shown: set() for s in scanned}
    for s, rel in zip(scanned, files, strict=True):
        lines = (root / rel).read_text(encoding="utf-8").splitlines()
        here = posixpath.dirname(rel.as_posix())
        for src in s.sources:
            for cand in source_candidates(src.arg, here, directive_above(lines, src.line)):
                target = by_rel.get(posixpath.normpath(cand))
                if target is not None:
                    graph[s.shown].add(target)
                    break
    return graph


def coupling(root: Path, scanned: list[Scanned], files: list[Path], scope: str, *, cycles: bool, fan: bool) -> Collected:
    keys, findings = _python().coupling_keys(source_graph(root, scanned, files), scope, cycles=cycles, fan=fan)
    return Collected(keys, findings)


def shellcheck(root: Path, files: list[Path], scanned: list[Scanned], scope: str) -> Collected:
    """shellcheck's errors and warnings, plus devkit's stdin-in-read-loop as warnings."""
    proc = subprocess.run(
        [str(SHELLCHECK), "--format=json1", *(f.as_posix() for f in files)],
        cwd=root, capture_output=True, text=True, check=False,
    )  # fmt: skip
    if proc.returncode not in (0, 1):
        raise CollectorError(
            f"devkit/bin/shellcheck.sh exited {proc.returncode} (the pinned shellcheck comes "
            f"from devkit/bin/release_tool.sh shellcheck)\n{proc.stderr[-2000:]}"
        )
    try:
        comments = json.loads(proc.stdout)["comments"]
        seen = {(c["level"], c["file"], c["line"], c["column"], c["code"], c["message"]) for c in comments}
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise CollectorError(f"unparseable shellcheck json1 output: {exc}") from exc
    out = Collected()
    own = [(s.shown, line, f"{STDIN_CHECK} {msg}") for s in scanned for line, msg in s.stdin_readers]
    for level, stat in COUNTED_LEVELS.items():
        hits = sorted(
            (shown(root, f), line, col, f"SC{code} {msg}") for lv, f, line, col, code, msg in seen if lv == level
        )
        rows = [(path, line, text) for path, line, _, text in hits] + (own if level == "warning" else [])
        key = f"lint.{scope}.{stat}"
        out.keys[key] = len(rows)
        out.findings[key] = [f"{path}:{line} {text}" for path, line, text in sorted(rows)]
    return out


# ------------------------------------------------------------------------------- cli


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="shell.py", description="Shell lint, complexity and dead-function metrics."
    )
    parser.add_argument("--root", required=True, help="the repo (globs are relative to it)")
    parser.add_argument("--scope", required=True, help="the key's middle segment (infra, ...)")
    parser.add_argument("--src", action="append", metavar="GLOB",
                        help=f"files to measure, root-relative (default: {' '.join(DEFAULT_SRC)})")  # fmt: skip
    parser.add_argument("--exclude", action="append", default=[], metavar="GLOB",
                        help="root-relative paths to leave out (fnmatch)")  # fmt: skip
    parser.add_argument("--out", help="write the JSON here (default: stdout)")
    parser.add_argument("--shellcheck", action="store_true", help="shellcheck errors and warnings")
    parser.add_argument("--complexity", action="store_true", help="branches per function")
    parser.add_argument("--dead", action="store_true", help="functions nothing calls")
    parser.add_argument("--entry", action="append", default=[], metavar="NAME",
                        help="with --dead: a function called from outside the set")  # fmt: skip

    parser.add_argument("--cycles", action="store_true", help="files that source each other")
    parser.add_argument("--fan", action="store_true", help="how many files a file sources, and is sourced by")
    parser.add_argument(
        "--list-out",
        metavar="FILE",
        help="also write the findings behind each count here, one line each (plain text)",
    )
    return parser


def collect(args: argparse.Namespace) -> Collected:
    root = Path(args.root)
    if not root.is_dir():
        raise CollectorError(f"--root {root} is not a directory")
    if SCOPE.fullmatch(args.scope) is None:
        raise CollectorError(f"--scope {args.scope!r} must match [A-Za-z0-9_-]+")
    if not (args.shellcheck or args.complexity or args.dead or args.cycles or args.fan):
        raise CollectorError("nothing to collect: pass --shellcheck, --complexity, --dead, --cycles or --fan")
    if args.entry and not args.dead:
        raise CollectorError("--entry declares an entry point for --dead; pass --dead too")
    files = source_files(root, args.src or list(DEFAULT_SRC), args.exclude)
    parts: list[Collected] = []
    scanned = scan_files(root, files)
    if args.complexity:
        parts.append(complexity(scanned, args.scope))
    if args.dead:
        parts.append(dead(scanned, args.scope, frozenset(args.entry)))

    if args.cycles or args.fan:
        parts.append(coupling(root, scanned, files, args.scope, cycles=args.cycles, fan=args.fan))
    if args.shellcheck:
        parts.append(shellcheck(root, files, scanned, args.scope))
    out = Collected()
    for part in parts:
        out.keys.update(part.keys)
        out.findings.update(part.findings)
    return out


def findings_text(findings: dict[str, list[str]]) -> str:
    """python.py's --list-out bytes: `# <key>` then its lines, keys sorted, empty keys left out."""
    lines = [
        line for key in sorted(findings) if findings[key] for line in (f"# {key}", *findings[key])
    ]
    return "".join(f"{line}\n" for line in lines)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        collected = collect(args)
        text = json.dumps(collected.keys, indent=2, sort_keys=True) + "\n"
        if args.out is None:
            sys.stdout.write(text)
        else:
            _write(Path(args.out), text)
        if args.list_out is not None:
            _write(Path(args.list_out), findings_text(collected.findings))
    except CollectorError as exc:
        print(f"metrics/shell.py: {exc}", file=sys.stderr)
        return EXIT_USAGE
    return 0


if __name__ == "__main__":
    sys.exit(main())
