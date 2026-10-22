#!/usr/bin/env python3
"""Guard for ci-quick in a Swift app (the consumer's `ios-check` target, in `ci-guards`): the
two iOS rules no compiler enforces, declared in `scripts/ci/ios.conf`.

  python3 -I devkit/bin/ios_check.py [--root .] [--conf scripts/ci/ios.conf]

The conf, one directive per line; a lone `#` word starts a comment:

  brand <path/to/Brand.xcconfig>         exactly one
  crash sentry                           exactly one crash line: sentry-cocoa reports crashes,
  crash none <decisions anchor>            or docs/decisions.md records why this app does not
  known <path>:<line> <rule> <reason>    an allowance for one finding (two on a line need two
                                           lines); it must still fire

brand: the xcconfig is the app's one brand source (bundle id base, app group, URL scheme, log
subsystem, Sentry DSN), reaching Swift through Info.plist keys. The non-empty value of every
`BRAND_*` key, `$(NAME)` references to the file's keys expanded (`$()` is empty, xcconfig's
escape for the `//` it reads as a comment), is a brand value, each conditional assignment
(`BRAND_X[sdk=iphoneos*]`) its own; other settings in the file (locus's SWIFT_OPTIMIZATION_LEVEL)
are not. A reference takes only the values a build of its own conditions can select, condition
patterns compared as globs (`iphoneos*` overlaps `iphoneos26*`, not `iphonesimulator*`), and
the references of one value agree on one build. A Swift string literal whose ENTIRE value equals a
brand value fails, naming the key. Whole-literal
only: "io.silversky.locus" fires, "locus.sqlite" and "\\(id).locus" do not. A value naming a key
the file does not define is left out. Every tracked or untracked-unignored *.swift outside
devkit/ is scanned; comments, interpolations and multi-line (\"\"\") literals never match.

crash sentry: sentry-cocoa is a dependency (`sentry-cocoa` in a Package.resolved or project.yml)
and `SentrySDK.start` is called (`start(…)`, `start { … }`, `start(configureOptions:) { … }`;
a bare or `start(options:)` reference left unapplied is not a call) at exactly one site in
Swift code (not a comment or string): two starts race, and none means the package ships but
reports nothing. `crash none <anchor>`:
<anchor> (with or without `#`) is the GitHub slug of a `#` heading in docs/decisions.md.

Output: `ios-check: <path>:<line>: <rule>: <message>` per finding on stderr (a conf-level
finding points at the conf line), then `ios-check: ok (<n> swift files, <m> brand values)` on
stdout or `ios-check: FAIL (<n> findings)` on stderr. Exit 0 ok, 1 findings (a stale `known`
line is one), 2 usage: no conf, a missing brand file, a bad or missing directive, not a git
work tree.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

EXIT_USAGE = 2
PREFIX = "ios-check"
XCCONFIG_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)((?:\s*\[[^\]]*\])*)\s*=\s*(.*)$")
XCCONFIG_REF = re.compile(r"\$[({]([A-Za-z0-9_]*)[)}]")
# A line starting `#`, or a lone `#` word, is a comment, so an anchor keeps its own `#`
# (`crash none #2026-10-21--why`).
CONF_COMMENT = re.compile(r"^\s*#.*$|\s#(\s.*)?$")
# A call: `start(…)`, a trailing closure `start {`, or a labelled reference applied at once
# (`start(configureOptions:) { … }`, `start(options:)(o)`). A bare `SentrySDK.start` or a
# labelled reference left alone is a function value, which starts nothing.
SENTRY_START = re.compile(
    r"\bSentrySDK\s*\.\s*start\s*"
    r"(?:\{|\((?!\s*(?:\w+\s*:\s*)+\)(?!\s*[({])))"
)
SIMPLE_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


class UsageError(Exception):
    pass


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str

    def render(self) -> str:
        return f"{PREFIX}: {self.path}:{self.line}: {self.rule}: {self.message}"


@dataclass(frozen=True)
class Conf:
    path: str
    brand: tuple[str, int]  # (xcconfig path, conf line)
    crash: tuple[list[str], int]  # (["sentry"] | ["none", anchor], conf line)
    # (path, line, rule) -> its conf lines; each line allows one finding, so two findings on
    # one source line need two `known` lines.
    known: dict[tuple[str, int, str], list[int]]


# ---- conf --------------------------------------------------------------------------------


def parse_conf(conf_path: Path, rel: str) -> Conf:
    brand: tuple[str, int] | None = None
    crash: tuple[list[str], int] | None = None
    known: dict[tuple[str, int, str], list[int]] = {}
    for n, raw in enumerate(conf_path.read_text(encoding="utf-8").splitlines(), 1):
        words = CONF_COMMENT.sub("", raw).split()
        if not words:
            continue
        key, args = words[0], words[1:]
        if key == "brand" and len(args) == 1 and brand is None:
            brand = (args[0], n)
        elif key == "crash" and crash is None and args[:1] in (["sentry"], ["none"]) and (
                len(args) == (1 if args[0] == "sentry" else 2)):
            crash = (args, n)
        elif key == "known" and len(args) >= 3 and re.fullmatch(r".+:\d+", args[0]):
            path, line = args[0].rsplit(":", 1)
            known.setdefault((path, int(line), args[1]), []).append(n)
        else:
            raise UsageError(f"{rel}:{n}: not a directive (or a second brand/crash line): {raw}")
    if brand is None or crash is None:
        raise UsageError(
            f"{rel}: needs one `brand <xcconfig>` and one `crash sentry|none <anchor>`"
        )
    return Conf(rel, brand, crash, known)


# ---- xcconfig ----------------------------------------------------------------------------


# {key: {conditions: value}}: `BRAND_X[sdk=iphoneos*]` and `BRAND_X` are separate settings,
# both live (each for the builds its conditions select); "" is the unconditional one.
Settings = dict[str, dict[str, str]]
# What a build has been narrowed to: per selector, the patterns its value must match, all of
# them (`sdk` -> {"iphoneos*", "iphoneos26*"} is an iPhoneOS 26 build).
Conditions = dict[str, frozenset[str]]
# One value a setting can take, with the conditions of the build that takes it.
Expansion = tuple[str, Conditions]
CONDITION = re.compile(r"\[([^=\]]+)=([^\]]*)\]")


def brand_values(xcconfig: Path) -> dict[str, str]:
    """{value: key} for every resolvable, non-empty BRAND_* assignment. Xcode reads `//` as a
    comment even inside a value; a later assignment wins over an earlier one of the same key and
    conditions, as in Xcode, so a device-only and a simulator-only value are both brand values."""
    raw: Settings = {}
    for line in xcconfig.read_text(encoding="utf-8").splitlines():
        m = XCCONFIG_ASSIGN.match(line.split("//", 1)[0])
        if m:
            conditions = re.sub(r"\s+", "", m.group(2))
            raw.setdefault(m.group(1), {})[conditions] = m.group(3).strip()
    values: dict[str, str] = {}
    for key in (k for k in raw if k.startswith("BRAND_")):
        for value in sorted({v for v, _ in expand(key, raw, (), {})}):
            if value:
                values.setdefault(value, key)
    return values


def globs_intersect(patterns: frozenset[str]) -> bool:
    """Some string matches every pattern (xcconfig condition values: `*` is the one wildcard).
    `iphoneos*` and `iphoneos26*` do (iphoneos26.0); `iphoneos*` and `iphonesimulator*` do not.
    A search over one position per pattern: a `*` may match nothing (step past it), and a
    character every pattern accepts advances each literal and keeps each `*`."""
    pats = tuple(patterns)
    todo, seen = [tuple(0 for _ in pats)], set()
    while todo:
        state = todo.pop()
        if state in seen:
            continue
        seen.add(state)
        if all(i == len(p) for i, p in zip(state, pats, strict=True)):
            return True
        for k, (i, p) in enumerate(zip(state, pats, strict=True)):
            if i < len(p) and p[i] == "*":
                todo.append((*state[:k], i + 1, *state[k + 1:]))
        heads = {p[i] for i, p in zip(state, pats, strict=True) if i < len(p) and p[i] != "*"}
        if len(heads) == 1 and all(i < len(p) for i, p in zip(state, pats, strict=True)):
            todo.append(tuple(i + (p[i] != "*") for i, p in zip(state, pats, strict=True)))
    return False


def glob_covers(general: str, specific: str) -> bool:
    """Every string `specific` matches, `general` matches too: `general` matches `specific` read
    as text, each of its `*` matchable only by a `*` of `general`. Sound, not complete: a False
    keeps a fallback assignment selectable, the cautious side (one more brand value)."""
    regex = "".join(".*" if c == "*" else re.escape(c) for c in general)
    return re.fullmatch(regex, specific, re.DOTALL) is not None


def variants(key: str, raw: Settings, active: Conditions) -> list[tuple[str, Conditions]]:
    """(value, conditions) of each assignment of `key` a build narrowed to `active` can select:
    one whose pattern no such build matches cannot (patterns compare as globs, so `iphoneos*`
    and `iphoneos26*` overlap), and the unconditional one cannot when a conditional one is sure
    to match every such build (Xcode takes the most specific)."""
    found = []
    for spec, text in raw[key].items():
        conds = {sel: frozenset({pat}) for sel, pat in CONDITION.findall(spec)}
        if all(globs_intersect(active.get(sel, frozenset()) | pats) for sel, pats in conds.items()):
            found.append((text, conds))
    if any(c and all(certain(active.get(sel, frozenset()), pats) for sel, pats in c.items())
           for _, c in found):
        found = [(t, c) for t, c in found if c]
    return found


def certain(active: frozenset[str], pats: frozenset[str]) -> bool:
    """Every build matching all of `active` matches each of `pats`."""
    return all(any(glob_covers(pat, a) for a in active) for pat in pats)


def narrow(active: Conditions, conds: Conditions) -> Conditions:
    return {sel: active.get(sel, frozenset()) | conds.get(sel, frozenset())
            for sel in active.keys() | conds.keys()}


def expand(key: str, raw: Settings, seen: tuple[str, ...], active: Conditions) -> list[Expansion]:
    """Every value `key` can take in a build narrowed to `active`, with the conditions of the
    build that takes it: one per selectable assignment, each `$(NAME)` expanded under that
    assignment's conditions AND those the references before it chose, so a device-only setting
    never borrows a simulator-only value and `$(A)$(B)` never mixes A's device value with B's
    simulator one (devkit#188). A cycle or a key the file does not define yields nothing."""
    if key in seen or key not in raw:
        return []
    out: list[Expansion] = []
    for text, conds in variants(key, raw, active):
        partials, pos = [("", narrow(active, conds))], 0
        for m in XCCONFIG_REF.finditer(text):
            lead = text[pos:m.start()]
            if not m.group(1):  # `$()`: empty
                partials = [(p + lead, c) for p, c in partials]
            else:
                partials = [(p + lead + v, c2) for p, c in partials
                            for v, c2 in expand(m.group(1), raw, (*seen, key), c)]
            pos = m.end()
        out += [(p + text[pos:], c) for p, c in partials]
    return out


# ---- swift lexer -------------------------------------------------------------------------


@dataclass(frozen=True)
class Literal:
    value: str
    line: int
    plain: bool  # single-line, no interpolation: the only kind the brand rule compares


class SwiftLexer:
    """Splits Swift source into code (strings and comments blanked, newlines kept, so offsets
    and line numbers survive) and its top-level string literals."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.code: list[str] = []
        self.literals: list[Literal] = []

    def run(self) -> tuple[str, list[Literal]]:
        i, n = 0, len(self.text)
        while i < n:
            end = self.skip_comment(i)
            if end == i:
                end = self.string_at(i, record=True)
            if end == i:
                self.code.append(self.text[i])
                end = i + 1
            else:
                self.code.append(re.sub(r"[^\n]", " ", self.text[i:end]))
            i = end
        return "".join(self.code), self.literals

    def skip_comment(self, i: int) -> int:
        t = self.text
        if t.startswith("//", i):
            nl = t.find("\n", i)
            return len(t) if nl < 0 else nl
        if not t.startswith("/*", i):
            return i
        depth, j = 0, i
        while j < len(t):
            if t.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif t.startswith("*/", j):
                depth, j = depth - 1, j + 2
                if depth == 0:
                    return j
            else:
                j += 1
        return len(t)

    def string_at(self, i: int, record: bool) -> int:
        """End offset of the string literal opening at i, or i when none opens there."""
        t = self.text
        j = i
        while j < len(t) and t[j] == "#":
            j += 1
        if j >= len(t) or t[j] != '"':
            return i
        hashes = j - i
        multi = t.startswith('"""', j)
        end, value, interp = self.scan_body(j + (3 if multi else 1), hashes, multi)
        if record:
            line = t.count("\n", 0, i) + 1
            self.literals.append(Literal(value, line, not multi and not interp))
        return end

    def scan_body(self, j: int, hashes: int, multi: bool) -> tuple[int, str, bool]:
        t, quote = self.text, ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        out: list[str] = []
        interp = False
        while j < len(t):
            if t.startswith(quote, j):
                return j + len(quote), "".join(out), interp
            if not multi and t[j] == "\n":
                break  # unterminated: let the compiler say so
            if t.startswith(escape, j):
                j, piece, is_interp = self.scan_escape(j + len(escape))
                interp = interp or is_interp
                out.append(piece)
                continue
            out.append(t[j])
            j += 1
        return j, "".join(out), interp

    def scan_escape(self, j: int) -> tuple[int, str, bool]:
        t = self.text
        if j >= len(t):
            return j, "", False
        if t[j] == "(":
            return self.skip_interpolation(j + 1), "", True
        if t.startswith("u{", j):
            close = t.find("}", j)
            if close > 0:
                try:
                    return close + 1, chr(int(t[j + 2:close], 16)), False
                except ValueError:
                    pass
        return j + 1, SIMPLE_ESCAPES.get(t[j], t[j]), False

    def skip_interpolation(self, j: int) -> int:
        depth, t = 1, self.text
        while j < len(t) and depth:
            end = self.skip_comment(j)
            if end == j:
                end = self.string_at(j, record=False)
            if end != j:
                j = end
                continue
            depth += {"(": 1, ")": -1}.get(t[j], 0)
            j += 1
        return j


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


# ---- rules -------------------------------------------------------------------------------


def repo_files(root: Path) -> list[str]:
    """The tracked and untracked-unignored files the rules read (Swift sources, the manifests
    that pin sentry-cocoa), outside the vendored devkit/; ignored build trees never count."""
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard",
         "--", "*.swift", "*Package.resolved", "*project.yml"],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise UsageError(f"{root} is not a git work tree")
    paths = {p for p in proc.stdout.split("\0") if p and not p.startswith("devkit/")}
    return sorted(p for p in paths if (root / p).is_file())


def brand_findings(lexed: dict[str, tuple[str, list[Literal]]], values: dict[str, str],
                   brand_rel: str) -> list[Finding]:
    return [
        Finding(path, lit.line, "brand",
                f'"{lit.value}" is {values[lit.value]} in {brand_rel}; read it through Brand '
                "(Info.plist), never a literal")
        for path, (_, literals) in lexed.items()
        for lit in literals
        if lit.plain and lit.value in values
    ]


def sentry_declared(root: Path, manifests: list[str]) -> bool:
    return any(
        "sentry-cocoa" in (root / p).read_text(encoding="utf-8", errors="replace").lower()
        for p in manifests
    )


def crash_findings(root: Path, conf: Conf, manifests: list[str],
                   lexed: dict[str, tuple[str, list[Literal]]]) -> list[Finding]:
    args, conf_line = conf.crash
    if args[0] == "none":
        anchor = args[1].lstrip("#")
        if anchor in decision_slugs(root / "docs" / "decisions.md"):
            return []
        return [Finding(conf.path, conf_line, "crash",
                        f"`crash none {args[1]}`: no heading with that anchor in "
                        "docs/decisions.md")]
    found: list[Finding] = []
    if not sentry_declared(root, manifests):
        found.append(Finding(conf.path, conf_line, "crash",
                             "sentry-cocoa is in no Package.resolved or project.yml"))
    sites = [(path, line_of(code, m.start()))
             for path, (code, _) in lexed.items() for m in SENTRY_START.finditer(code)]
    if len(sites) != 1:
        found += [Finding(p, ln, "crash",
                          f"{len(sites)} SentrySDK.start call sites; want exactly one, first in "
                          "App.init")
                  for p, ln in sites or [(conf.path, conf_line)]]
    return found


def decision_slugs(decisions: Path) -> set[str]:
    """GitHub's heading anchors: lowercased, punctuation (the em dash too) dropped, spaces to
    hyphens, so `## 2026-10-21 — No crash reporting` is `2026-10-21--no-crash-reporting`."""
    if not decisions.is_file():
        return set()
    slugs = set()
    for line in decisions.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^#{1,6}\s+(.*?)\s*$", line)
        if m:
            slugs.add(re.sub(r"[^\w\- ]", "", m.group(1).lower()).replace(" ", "-"))
    return slugs


def apply_known(conf: Conf, findings: list[Finding]) -> list[Finding]:
    """Each `known` line absorbs one finding; a finding past its allowances stays, and a line
    left over is stale."""
    unused = {key: list(lines) for key, lines in conf.known.items()}
    kept = []
    for f in findings:
        lines = unused.get((f.path, f.line, f.rule))
        if lines:
            lines.pop(0)
        else:
            kept.append(f)
    for (path, line, rule), lines in unused.items():
        kept += [Finding(conf.path, n, "stale-known",
                         f"known {path}:{line} {rule} matches no finding; delete it")
                 for n in lines]
    return kept


def run(root: Path, conf_rel: str) -> tuple[list[Finding], int, int]:
    conf_path = root / conf_rel
    if not conf_path.is_file():
        raise UsageError(f"{conf_rel}: no such conf (see the ios_check.py header)")
    conf = parse_conf(conf_path, conf_rel)
    brand_rel = conf.brand[0]
    if not (root / brand_rel).is_file():
        raise UsageError(f"{conf_rel}:{conf.brand[1]}: brand file {brand_rel} does not exist")
    values = brand_values(root / brand_rel)
    files = repo_files(root)
    lexed = {
        p: SwiftLexer((root / p).read_text(encoding="utf-8", errors="replace")).run()
        for p in files if p.endswith(".swift")
    }
    manifests = [p for p in files if not p.endswith(".swift")]
    findings = (brand_findings(lexed, values, brand_rel)
                + crash_findings(root, conf, manifests, lexed))
    return apply_known(conf, findings), len(lexed), len(values)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--root", default=".", help="the app repo's root (default .)")
    ap.add_argument("--conf", default="scripts/ci/ios.conf", help="relative to --root")
    args = ap.parse_args()
    try:
        findings, files, values = run(Path(args.root).resolve(), args.conf)
    except UsageError as e:
        print(f"{PREFIX}: {e}", file=sys.stderr)
        return EXIT_USAGE
    for f in sorted(findings, key=lambda f: (f.path, f.line, f.rule)):
        print(f.render(), file=sys.stderr)
    if findings:
        print(f"{PREFIX}: FAIL ({len(findings)} findings)", file=sys.stderr)
        return 1
    print(f"{PREFIX}: ok ({files} swift files, {values} brand values)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
