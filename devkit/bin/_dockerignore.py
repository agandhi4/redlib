#!/usr/bin/env python3
"""Which repo paths a `docker build .` can see: the root .dockerignore, matched as Docker does.

Used by: _paths_lib.sh (the gate's image-area classifier, `keep`) and devkit-check.sh (the
redundant GATE_IMAGE_EXCLUDE_PATHS warning, `redundant`). Every fleet image builds the root
context (`docker build … .`), so the root .dockerignore is the one that applies.

Gotcha: Docker's matcher is not gitignore's. It is moby/patternmatcher, mirrored here: each
pattern is Go-`filepath.Clean`ed with any leading `/` dropped, then matched against the WHOLE
path from the context root, so an unanchored `*.md` matches `README.md` but not `docs/a.md`
(gitignore would match both). A pattern that matches a parent directory excludes everything
under it; `**` matches any number of directories, zero included; `!` re-includes; the last
matching pattern wins. The .dockerignore and the root Dockerfile shape the build even when a
pattern names them (redlib ignores `Dockerfile*`), so they are always kept. Checked against
`docker build -o` of a scratch image on Docker 29.4 (tests/dockerignore_test.py's cases).

  _dockerignore.py keep <context dir>              stdin: paths; stdout: those the build sees
  _dockerignore.py redundant <context dir> <ERE>   stdin: tracked paths; stdout: one line per
      alternative of a `^(a|b|…)` ERE (else the whole ERE) whose every matching path the
      .dockerignore already excludes. Python's re reads the ERE: the fleet's are plain ones.

Exit 0, or 2 on a bad call or an unreadable .dockerignore.
"""

from __future__ import annotations

import posixpath
import re
import sys
from dataclasses import dataclass
from pathlib import Path

EXIT_USAGE = 2
ALWAYS_KEPT = re.compile(r"^(\.dockerignore|Dockerfile)$")
GO_REGEX_SPECIAL = set(".+()|{}$")  # what patternmatcher escapes; `[`, `]`, `^` pass through


@dataclass(frozen=True)
class Pattern:
    regex: re.Pattern[str]
    exclusion: bool  # a `!` line: re-includes what it matches


def _go_clean(path: str) -> str:
    """filepath.Clean for slash paths: normpath, but `//x` is `/x` as in Go."""
    cleaned = posixpath.normpath(path)
    return "/" + cleaned.lstrip("/") if cleaned.startswith("/") else cleaned


def _compile(pattern: str) -> re.Pattern[str]:
    """patternmatcher's Pattern.compile, separator `/`."""
    out, i = "^", 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "*":
            if i + 1 < len(pattern) and pattern[i + 1] == "*":
                i += 1
                if i + 1 < len(pattern) and pattern[i + 1] == "/":
                    i += 1  # `**/` is `**`
                out += ".*" if i + 1 == len(pattern) else "(.*/)?"
            else:
                out += "[^/]*"
        elif ch == "?":
            out += "[^/]"
        elif ch == "\\":
            i += 1
            if i < len(pattern):
                out += re.escape(pattern[i])
        elif ch in GO_REGEX_SPECIAL:
            out += "\\" + ch
        else:
            out += ch
        i += 1
    return re.compile(out + "$")


def parse(text: str) -> list[Pattern]:
    """ignorefile.ReadAll then patternmatcher.New: comments, blanks, `!`, Clean, no leading /."""
    patterns: list[Pattern] = []
    for raw in text.removeprefix("﻿").splitlines():
        if raw.startswith("#"):
            continue
        line = raw.strip()
        if not line:
            continue
        exclusion = line.startswith("!")
        if exclusion:
            line = line[1:].strip()
        if not line:
            continue
        line = _go_clean(line)
        if len(line) > 1 and line.startswith("/"):
            line = line[1:]
        patterns.append(Pattern(_compile(line), exclusion))
    return patterns


def excluded(path: str, patterns: list[Pattern]) -> bool:
    """patternmatcher.MatchesOrParentMatches: the last pattern matching the path or one of its
    parent directories decides."""
    path = _go_clean(path)
    parts = path.split("/")
    parents = ["/".join(parts[: i + 1]) for i in range(len(parts) - 1)]
    matched = False
    for pattern in patterns:
        if pattern.exclusion != matched:
            continue  # cannot change the verdict
        if pattern.regex.match(path) or any(pattern.regex.match(p) for p in parents):
            matched = not pattern.exclusion
    return matched


def kept(path: str, patterns: list[Pattern]) -> bool:
    return bool(ALWAYS_KEPT.match(path)) or not excluded(path, patterns)


def alternatives(ere: str) -> list[str]:
    """`^(a|b|c)` -> [`^a`, `^b`, `^c`], splitting only at top-level `|`; any other shape is
    one alternative, itself."""
    shape = re.fullmatch(r"\^\((.*)\)", ere)
    if not shape:
        return [ere]
    body, parts, depth, start, i = shape.group(1), [], 0, 0, 0
    in_class = False
    while i < len(body):
        ch = body[i]
        if ch == "\\":
            i += 2
            continue
        if in_class:
            in_class = ch != "]"
        elif ch == "[":
            in_class = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "|" and depth == 0:
            parts.append(body[start:i])
            start = i + 1
        i += 1
    if depth != 0:
        return [ere]
    parts.append(body[start:])
    return ["^" + part for part in parts]


def load(context: Path) -> list[Pattern]:
    path = context / ".dockerignore"
    try:
        return parse(path.read_text(encoding="utf-8")) if path.is_file() else []
    except (OSError, UnicodeDecodeError) as exc:
        print(f"_dockerignore: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(EXIT_USAGE)


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "keep":
        patterns = load(Path(argv[1]))
        for path in sys.stdin.read().splitlines():
            if path and kept(path, patterns):
                print(path)
        return 0
    if len(argv) == 3 and argv[0] == "redundant":
        patterns = load(Path(argv[1]))
        paths = [p for p in sys.stdin.read().splitlines() if p]
        for alt in alternatives(argv[2]):
            try:
                regex = re.compile(alt)
            except re.error as exc:
                print(f"_dockerignore: {alt!r} is not a regex Python reads: {exc}", file=sys.stderr)
                return EXIT_USAGE
            hits = [p for p in paths if regex.search(p)]
            if hits and all(not kept(p, patterns) for p in hits):
                print(alt)
        return 0
    print("usage: _dockerignore.py keep <context dir> | redundant <context dir> <ERE>", file=sys.stderr)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
