"""Swift package pins for metrics/vuln.py --swift, stdlib only (loaded by path, like _cvss.py).

A Swift project directory's pins come from the first of:
  1. <dir>/Package.resolved (a SwiftPM package), else the resolved files of a committed Xcode
     project or workspace in <dir> (*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/,
     *.xcworkspace/xcshareddata/swiftpm/). Formats v1 (`object.pins`, `repositoryURL`) and
     v2/v3 (`pins`, `location`, `kind`).
  2. No resolved file (an XcodeGen project ignores its .xcodeproj): the exact pins of
     <dir>/project.yml `packages:` (`exactVersion`/`version`) and <dir>/Package.swift
     (`exact:`/`.exact(...)`). A range, branch or revision there resolves to an unknown version,
     so it is an error, never a skipped package: the fix is to pin it or commit the resolved file.
     So is what this reader cannot see into (an XcodeGen `include:`, an inline `packages:`
     mapping, a `.package(` whose url is not a string literal): unread is not "no packages".
Local packages (a `path:`, `localSourceControl`) are the repo's own code; their dependencies are
their own --swift directory. A registry pin or a resolved pin with no version (a branch or
revision) is named on stderr and not queried: OSV keys SwiftURL advisories by version.

OSV's SwiftURL name is the repository URL without its scheme, `.git` or trailing slash, case kept
(github.com/apple/swift-nio; `git@github.com:o/r.git` is github.com/o/r). OSV matches it
case-sensitively, as each advisory's URL was typed (github.com/sparkle-project/Sparkle), but
GitHub and GitLab resolve owner/repo in any case: match_key folds those hosts' names, and
metrics/vuln.py queries a pin under every advisory spelling of its key (#257 missed a
github.com/sparkle-project/sparkle pin). Elsewhere the case is kept: a host may not fold it."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ECOSYSTEM = "SwiftURL"
CASELESS_HOSTS = ("github.com", "gitlab.com")
XCODE_RESOLVED = (
    "*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "*.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)


UNPINNED = "(a range or branch resolves to an unknown version): pin it or commit Package.resolved"


class PinError(Exception):
    """An unreadable or unpinned source; vuln.py exits 2 with it."""


def _not_queried(path: Path, why: str) -> None:
    print(f"vuln: {path}: {why}, not queried (OSV keys Swift by repository URL and version)",
          file=sys.stderr)  # fmt: skip


def osv_name(url: str) -> str:
    """The SwiftURL package name OSV keys a repository URL by."""
    name = re.sub(r"^[a-z+]+://", "", url.strip())
    name = re.sub(r"^[^@/]+@", "", name)  # git@ / user@ before the host
    name = re.sub(r"^([^/:]+):(?!\d+/)", r"\1/", name)  # scp form host:owner/repo, not host:port/
    name = name.rstrip("/")
    return name.removesuffix(".git")


def match_key(name: str) -> str:
    """An OSV SwiftURL name as the host resolves it: lowercased on a case-insensitive host."""
    host = name.partition("/")[0].lower()
    return name.lower() if host in CASELESS_HOSTS else name


def resolved_files(project: Path) -> list[Path]:
    own = project / "Package.resolved"
    if own.is_file():
        return [own]
    return sorted(f for pattern in XCODE_RESOLVED for f in project.glob(pattern))


def resolved_pins(path: Path) -> list[tuple[str, str]]:
    """(OSV name, version) of each remote pin in a Package.resolved."""
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        raise PinError(f"{path}: {e}") from e
    version = doc.get("version")
    pins = (doc.get("object") or {}).get("pins") if version == 1 else doc.get("pins")
    if version not in (1, 2, 3) or not isinstance(pins, list):
        raise PinError(f"{path}: not a Package.resolved v1, v2 or v3 (version {version!r})")
    out = []
    for pin in pins:
        url = pin.get("repositoryURL") if version == 1 else pin.get("location")
        kind = pin.get("kind", "remoteSourceControl")
        state = pin.get("state") or {}
        label = pin.get("identity") or pin.get("package") or url
        if kind == "localSourceControl":
            continue
        if kind != "remoteSourceControl" or not url:
            _not_queried(path, f"{label} is a {kind} pin")
        elif not state.get("version"):
            _not_queried(path, f"{label} is pinned to a revision with no version")
        else:
            out.append((osv_name(url), str(state["version"])))
    return out


def _unquote(value: str) -> str:
    return value.split(" #", 1)[0].strip().strip("'\"")


def xcodegen_pins(path: Path) -> list[tuple[str, str]]:
    """(OSV name, version) of each remote package in an XcodeGen project.yml, by indentation
    (no YAML library in the stdlib): `packages:` at column 0, one key per package below it."""
    try:
        lines = path.read_text().splitlines()
    except OSError as e:
        raise PinError(f"{path}: {e}") from e
    packages: dict[str, dict[str, str]] = {}
    inside, child, current = False, -1, ""
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0:
            # Split, then unquote: `packages: # third-party` and `"packages":` are the key too
            # (#257 Codex: each read 0 packages).
            top, _, inline = raw.partition(":")
            top = _unquote(top)
            if top == "include":
                # XcodeGen merges included specs, which may hold packages (#257 Codex).
                raise PinError(f"{path}: `include:` specs are not read: declare packages here, "
                               "or commit the resolved file")  # fmt: skip
            inside = top == "packages"
            if inside and _unquote(inline) not in ("", "{}"):
                raise PinError(f"{path}: an inline `packages:` mapping is not read: write one "
                               "package per line, or commit the resolved file")  # fmt: skip
            continue
        if not inside:
            continue
        if child < 0:
            child = indent
        key, _, value = raw.strip().partition(":")
        if indent == child:
            current = _unquote(key)
            packages[current] = {}
        elif current:
            packages[current][key.strip()] = _unquote(value)
    out = []
    for name, spec in packages.items():
        if "path" in spec:
            continue
        url = spec.get("url") or (f"github.com/{spec['github']}" if "github" in spec else "")
        version = spec.get("exactVersion") or spec.get("version")
        if not url or not version:
            raise PinError(f"{path}: package {name} has no exactVersion {UNPINNED}")
        out.append((osv_name(url), version))
    return out


# `.package(` [name: "…",] url:|path:|id: "<where>", then the requirement's line.
_MANIFEST_PACKAGE = re.compile(
    r'\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?(url|path|id):\s*"([^"]+)"\s*,?\s*([^\n]*)'
)
_MANIFEST_EXACT = re.compile(r"^(?:exact:\s*|\.exact\(\s*)\"([^\"]+)\"")


def manifest_pins(path: Path) -> list[tuple[str, str]]:
    """(OSV name, version) of each `.package(url:, exact:)` in a Package.swift. Whole-line `//`
    comments are dropped first (a URL's own `//` is not a comment), then `/* */` blocks."""
    try:
        lines = path.read_text().splitlines()
    except OSError as e:
        raise PinError(f"{path}: {e}") from e
    text = "\n".join(line for line in lines if not line.lstrip().startswith("//"))
    # A `/* … */` block disables what it holds, as Swift reads it (not nested; #257 Codex).
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    out = []
    for start in re.finditer(r"\.package\s*\(", text):
        declared = _MANIFEST_PACKAGE.match(text, start.start())
        if declared is None:
            # A URL in a constant, say: absent from the pins would read as no exposure.
            line = text.count("\n", 0, start.start()) + 1
            raise PinError(f"{path}: the `.package(` near line {line} is not a string-literal "
                           "url:/path:/id: (unread): commit Package.resolved")  # fmt: skip
        kind, where, rest = declared.groups()
        if kind == "path":
            continue
        if kind == "id":
            _not_queried(path, f"{where} is a registry package")
            continue
        exact = _MANIFEST_EXACT.match(rest.strip())
        if not exact:
            raise PinError(f"{path}: {where} is not pinned `exact:` {UNPINNED}")
        out.append((osv_name(where), exact.group(1)))
    return out


def pins(project: Path) -> dict[Path, list[tuple[str, str]]]:
    """Each source file read under a Swift project directory, with its (OSV name, version) pins."""
    if not project.is_dir():
        raise PinError(f"{project}: not a directory")
    resolved = resolved_files(project)
    if resolved:
        return {f: resolved_pins(f) for f in resolved}
    readers = (("project.yml", xcodegen_pins), ("Package.swift", manifest_pins))
    found = {f: reader(f) for f, reader in ((project / n, r) for n, r in readers) if f.is_file()}
    if not found:
        raise PinError(f"{project}: no Package.resolved, Xcode project resolved file, "
                       "project.yml or Package.swift")  # fmt: skip
    return found
