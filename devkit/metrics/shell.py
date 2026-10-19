#!/usr/bin/env python3
"""Shared shell metrics collector: shellcheck findings, branches per function, dead functions.

One line in scripts/ci/metrics.conf, run by devkit/bin/metrics_collect.sh, for example:
  shell-infra repo python3 -I devkit/metrics/shell.py --root . --scope infra \\
      --src '**/*.sh' --src '.githooks/*' --shellcheck --complexity --dead \\
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
  --complexity  complexity.<scope>.branches_max   decision points per function: `if`, `elif`,
                complexity.<scope>.branches_over_15  `case`, `for`, `while`, `until` in command
                                                  position and every `&&`/`||` (inside `[[ ]]`
                                                  too), counted in the innermost function. A
                                                  file's top level is one more unit, `<main>`:
                                                  a script's dispatch lives there. A `case` is
                                                  one branch however many arms, so an argument
                                                  parser does not read as complex. Not counted:
                                                  `&&`/`||` inside `(( ))`/`$(( ))`.
  --dead        dead.<scope>.unused               functions defined in the set whose name
                                                  appears nowhere in the set's code outside
                                                  their own body (comments blanked; strings,
                                                  heredocs, `trap fn EXIT` and `"$fn"` count as
                                                  uses, so it errs towards alive). Not seen: a
                                                  caller outside the set (a Makefile recipe) and
                                                  a name built at run time (`cmd_$1`).
                                                  The plan hooks bin/local_gate.sh calls
                                                  (gate_plan, gate_plan_extra, gate_cleanup)
                                                  are entry points, never dead.

The function scanner is lexical and stdlib-only: it tracks quotes, `$(...)`, `${...}`,
backticks, heredocs, `[[ ]]`, `case` patterns and `{ }`/`( )` nesting, which is what finding a
function's body and its command-position keywords needs. A file it cannot balance (an unclosed
quote, brace or heredoc it misreads) is exit 2 naming <path>:<line>, never a guessed number.

--list-out FILE: python.py's format (`# <key>` then one line per finding, keys sorted; empty
when there are none). Paths are --root joined with the root-relative path.
  shellcheck_errors, shellcheck_warnings   <path>:<line> SC<code> <message>, by path and line
  branches_over_15                         <path>:<line> <function> branches=<n>, worst first
  unused                                   <path>:<line> <function> function, by path and line

Deterministic. Output: a flat JSON object to --out (default stdout). Exit: 0 ok, 2 a missing
tool, a shellcheck that failed to run, a file the scanner cannot balance or a bad call.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

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

BRANCH_WORDS = frozenset({"if", "elif", "case", "for", "while", "until"})
# Reserved words after which the next word is again a command.
COMMAND_WORDS = frozenset({"then", "else", "do", "!", "time", "if", "elif", "while", "until"})
# A function name as bash accepts it in practice; also how a use is recognised in the code.
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_:.-]*")
# Longest first, so `;;&` is not read as `;;` then `&`.
OPERATORS = (";;&", ";;", ";&", "&&", "||", "|&", "<<<", "<<-", "<<", "&>>", "&>", ">>", ">&", "<&",
             "<>", ">|", ";", "&", "|", "(", ")", "<", ">")  # fmt: skip
WORD_END = frozenset(" \t\n;&|()<>")


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
    branches: int = 0


@dataclass
class Frame:
    kind: str  # brace, paren, case; fn-brace / fn-paren close a function
    state: str = ""  # a case's head | pattern | body


@dataclass
class Context:
    """One code_until's parse state: each `$(...)` gets its own, as bash parses it apart."""

    frames: list[Frame] = field(default_factory=list)
    cmd: bool = True  # the next word is in command position
    dbl: bool = False  # inside [[ ]]
    last: str = ""  # the previous token (`for ((` is arithmetic)
    pending_fn: Function | None = None  # `name()` read, its body not yet opened

    def case(self) -> Frame | None:
        return self.frames[-1] if self.frames and self.frames[-1].kind == "case" else None


@dataclass
class Scanned:
    shown: str
    code: str  # the text with comments blanked, offsets preserved
    units: list[Function]  # the functions, then the file's top level as MAIN


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

    def fail(self, what: str, line: int | None = None) -> CollectorError:
        return CollectorError(f"{self.shown}:{line or self.line}: {what}")

    def scan(self) -> Scanned:
        self.code_until(None)
        chars = list(self.s)
        for a, b in self.comments:
            chars[a:b] = " " * (b - a)
        return Scanned(self.shown, "".join(chars), [*self.functions, self.main])

    def branch(self) -> None:
        (self.open[-1] if self.open else self.main).branches += 1

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
                self.newline()
                ctx.cmd = True
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
                if self.operator(ctx, op, closer):
                    return
                ctx.last = op
            else:
                start, line = self.i, self.line
                word = self.word()
                self.on_word(ctx, word, start, line)
                ctx.last = word
        if closer is not None:
            raise self.fail("`$(` or `<(` never closed", start_line)
        if ctx.frames or ctx.pending_fn is not None:
            what = ctx.frames[-1].kind if ctx.frames else "function body"
            raise self.fail(f"unclosed {what} at end of file")

    def operator(self, ctx: Context, op: str, closer: str | None) -> bool:
        """Apply one operator; True when it is the `)` that ends this code_until."""
        case = ctx.case()
        if case is not None and case.state == "pattern" and not ctx.dbl and op in ("(", "|", ")"):
            if op == ")":  # a pattern's optional leading paren and its alternation are no-ops
                case.state, ctx.cmd = "body", True
        elif op in ("&&", "||"):
            self.branch()
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
                self.pop(ctx)
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

    def on_word(self, ctx: Context, word: str, start: int, line: int) -> None:
        case = ctx.case()
        if ctx.dbl:
            ctx.dbl = word != "]]"
        elif case is not None and case.state in ("head", "pattern"):
            if case.state == "head" and word == "in":
                case.state = "pattern"
            elif case.state == "pattern" and word == "esac":
                ctx.frames.pop()
                ctx.cmd = False
        elif not ctx.cmd:
            pass
        elif ctx.pending_fn is not None:
            if word != "{":
                raise self.fail(f"function {ctx.pending_fn.name}: a body other than {{ }} or ( )", line)
            self.push(ctx, "fn-brace")
        else:
            self.command_word(ctx, word, start, line)

    def command_word(self, ctx: Context, word: str, start: int, line: int) -> None:
        """A word in command position: a reserved word, a function definition or a command."""
        if word == "function":
            self.skip_blanks()
            name_start, name_line = self.i, self.line
            name = self.word()
            self.empty_parens()
            ctx.pending_fn = Function(name, name_line, name_start)
        elif word in BRANCH_WORDS:
            self.branch()
            if word == "case":
                ctx.frames.append(Frame("case", "head"))
            ctx.cmd = word not in ("case", "for")
        elif word in COMMAND_WORDS:
            pass
        elif word == "{":
            self.push(ctx, "brace")
        elif word == "}":
            if not ctx.frames or ctx.frames[-1].kind not in ("brace", "fn-brace"):
                raise self.fail("unbalanced `}`", line)
            self.pop(ctx)
        elif word == "esac" and ctx.case() is not None:
            ctx.frames.pop()
            ctx.cmd = False
        elif word == "[[":
            ctx.dbl, ctx.cmd = True, False
        elif self.empty_parens():
            ctx.pending_fn = Function(word, line, start)
        else:
            ctx.cmd = False

    def push(self, ctx: Context, kind: str) -> None:
        """Open a `{`/`(` frame; a pending definition's opens the function's body."""
        ctx.frames.append(Frame(kind))
        if ctx.pending_fn is not None:
            self.functions.append(ctx.pending_fn)
            self.open.append(ctx.pending_fn)
            ctx.pending_fn = None
        ctx.cmd = True

    def pop(self, ctx: Context) -> None:
        if ctx.frames.pop().kind.startswith("fn-"):
            self.open.pop().end = self.i
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


def complexity(scanned: list[Scanned], scope: str) -> Collected:
    units = [(f, s.shown) for s in scanned for f in s.units]
    over = sorted(
        ((f, path) for f, path in units if f.branches > BRANCHES_THRESHOLD),
        key=lambda p: (-p[0].branches, p[1], p[0].line),
    )
    key = f"complexity.{scope}.branches_over_{BRANCHES_THRESHOLD}"
    return Collected(
        keys={f"complexity.{scope}.branches_max": max((f.branches for f, _ in units), default=0),
              key: len(over)},
        findings={key: [f"{path}:{f.line} {f.name} branches={f.branches}" for f, path in over]},
    )  # fmt: skip


def dead(scanned: list[Scanned], scope: str) -> Collected:
    """A function is used when its name appears in the set's code outside its own body."""
    defined = {f.name for s in scanned for f in s.units if f.name != MAIN}
    uses: dict[str, list[tuple[str, int]]] = {name: [] for name in defined}
    for s in scanned:
        for m in NAME.finditer(s.code):
            if m.group() in uses:
                uses[m.group()].append((s.shown, m.start()))
    unused = []
    for s in scanned:
        for f in s.units:
            if f.name == MAIN or f.name in ENTRY_POINTS:
                continue
            outside = [u for u in uses[f.name] if u[0] != s.shown or not f.start <= u[1] < f.end]
            if not outside:
                unused.append((s.shown, f.line, f.name))
    key = f"dead.{scope}.unused"
    return Collected(
        keys={key: len(unused)},
        findings={key: [f"{p}:{line} {name} function" for p, line, name in sorted(unused)]},
    )


def shellcheck(root: Path, files: list[Path], scope: str) -> Collected:
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
    for level, stat in COUNTED_LEVELS.items():
        hits = sorted((f, line, col, code, msg) for lv, f, line, col, code, msg in seen if lv == level)
        key = f"lint.{scope}.{stat}"
        out.keys[key] = len(hits)
        out.findings[key] = [f"{shown(root, f)}:{line} SC{code} {msg}" for f, line, _, code, msg in hits]
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
    if not (args.shellcheck or args.complexity or args.dead):
        raise CollectorError("nothing to collect: pass --shellcheck, --complexity or --dead")
    files = source_files(root, args.src or list(DEFAULT_SRC), args.exclude)
    parts: list[Collected] = []
    if args.complexity or args.dead:
        scanned = scan_files(root, files)
        parts += [m(scanned, args.scope) for w, m in ((args.complexity, complexity), (args.dead, dead)) if w]
    if args.shellcheck:
        parts.append(shellcheck(root, files, args.scope))
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
