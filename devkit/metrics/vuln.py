#!/usr/bin/env python3
"""Shared vulnerability collector: known vulnerabilities in the locked production dependencies.

Scorecard T11 `sec.audit` (owner, 2026-10-16: security is one of the tracks every repo is
raised on). One tool for every stack, so Python, Node and Rust repos get the same keys from
one line in scripts/ci/metrics.conf: it reads the LOCKED production dependency set and asks
OSV (https://osv.dev, the aggregate of GitHub advisories, PyPA, RustSec and npm) in one batch
query, then fetches each hit once for its severity. Nothing is installed and no audit tool
has to exist on the machine (pip-audit cannot build its venv on this Mac; cargo-audit is not
installed; `npm audit` needs a registry login shape OSV does not).

  vuln-backend  backend  python3 -I devkit/metrics/vuln.py --scope backend --uv backend \\
      --out build/metrics/vuln-backend.json
  vuln-frontend frontend python3 -I devkit/metrics/vuln.py --scope frontend \\
      --npm-lock frontend/package-lock.json --out build/metrics/vuln-frontend.json
  vuln-app      backend  python3 -I devkit/metrics/vuln.py --scope app --cargo-lock Cargo.lock ...

Sources (repeatable, mixed):
  --uv <project dir>        `uv export --frozen --no-dev --no-hashes` (production set of the lock)
  --npm-lock <file>         package-lock.json v2/v3 `packages`, entries without `dev: true`
  --pnpm-lock <file>        pnpm-lock.yaml v9: the closure of every importer's `dependencies`
                            (never `devDependencies`) through `snapshots`, parsed by indentation
                            (no YAML library in the stdlib); a package reached both ways is production
  --cargo-lock <file>       Cargo.lock `[[package]]` entries (no dev split in the lock format)
  --compose <file>...       compose files: the `image:` of every service (bin/_compose.py reads
                            them, extends resolved). OSV indexes no container image, so these
                            are counted, not queried: the image keys below, and no
                            critical/high/total/packages keys when no lockfile is given

Keys (docs/metrics-keys.md, domain `vuln`, direction lower; REPORT-ONLY, never a tracked
bound: a new advisory moves the number without a code change, so the ratchet must not fail a
PR for it, and the scorecard reads the snapshot instead):
  vuln.<scope>.critical   vulnerabilities whose severity is CRITICAL
  vuln.<scope>.high       HIGH
  vuln.<scope>.total      every known vulnerability affecting a locked production package
  vuln.<scope>.packages   the locked production packages queried; 0 is a dev-only lockfile
                          (instalite's web/), which the scorecard reads as `ratchet.vuln` NA:
                          there is no production exposure to measure
and one `vuln: <severity> <package>@<version> <id>` line per hit on stderr, worst first.
With --compose:
  vuln.<scope>.images             service image references
  vuln.<scope>.images_unpinned    neither a digest nor a tag other than `latest` (no tag is
                                  latest): a pull may bring any version, vulnerable or not
  vuln.<scope>.images_undigested  no `@sha256:` digest: a tag can be re-pushed, a digest cannot
and one `vuln: unpinned <file>:<line> <service> <image>` line per unpinned image on stderr.

Severity: OSV `database_specific.severity` when present, else the CVSS v3/v4 base score
banded (>= 9 CRITICAL, >= 7 HIGH, >= 4 MODERATE, else LOW), else UNKNOWN (counted in total).
Determinism: the same lockfile gives the same answer for a given day; the keys are dated by
the snapshot, not by the code, which is why they stay untracked. Exit 2 on an unreadable
source, a `uv export` failure, or an OSV error (no silent zero: a collector that cannot reach
its source reports nothing rather than a clean score). OSV_URL overrides the endpoint (tests).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from collections.abc import Iterator
from pathlib import Path
from types import ModuleType

EXIT_USAGE = 2
OSV_URL = os.environ.get("OSV_URL", "https://api.osv.dev")
BATCH = 1000  # OSV's querybatch limit
ORDER = ["CRITICAL", "HIGH", "MODERATE", "LOW", "UNKNOWN"]


class CollectorError(Exception):
    """An unreadable source or an OSV failure (exit 2)."""


def _compose_reader() -> ModuleType:
    """bin/_compose.py by path (`python3 -I` keeps it off sys.path; VENDOR_PATHS vendors bin/
    beside metrics/), the reader guard_check.py's compose rules use."""
    name = "devkit_compose"
    if name in sys.modules:
        return sys.modules[name]
    path = Path(__file__).resolve().parent.parent / "bin" / "_compose.py"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CollectorError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: its dataclasses look their module up
    sys.dont_write_bytecode = True  # a consumer's vendored devkit/ stays byte-identical
    spec.loader.exec_module(module)
    return module


def compose_images(files: list[str], scope: str) -> dict[str, int]:
    """The image keys over the compose files' services; each unpinned one named on stderr."""
    reader = _compose_reader()
    refs = []
    for f in files:
        try:
            refs.extend((f, s) for s in reader.services(Path(f), f) if s.image is not None)
        except (reader.YamlError, reader.ComposeError) as exc:
            raise CollectorError(str(exc)) from exc
    unpinned = [(f, s) for f, s in refs if s.image.unpinned]
    for f, s in unpinned:
        print(f"vuln: unpinned {f}:{s.line} {s.name} {s.spec['image']}", file=sys.stderr)
    print(f"vuln: {len(refs)} compose images, {len(unpinned)} unpinned", file=sys.stderr)
    return {
        f"vuln.{scope}.images": len(refs),
        f"vuln.{scope}.images_unpinned": len(unpinned),
        f"vuln.{scope}.images_undigested": sum(1 for _, s in refs if not s.image.digest),
    }


def uv_packages(project: Path) -> list[tuple[str, str, str]]:
    if not (project / "uv.lock").is_file():
        raise CollectorError(f"{project}: no uv.lock")
    proc = subprocess.run(
        ["uv", "export", "--frozen", "--no-dev", "--format", "requirements-txt", "--no-hashes", "--project", str(project)],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise CollectorError(f"uv export failed in {project}: {proc.stderr.strip()[:200]}")
    out = []
    for line in proc.stdout.splitlines():
        m = re.match(r"^([A-Za-z0-9_.-]+)(?:\[[^\]]*\])?==([^\s;]+)", line)
        if m:
            out.append(("PyPI", m.group(1).lower(), m.group(2)))
    return out


def npm_packages(lock: Path) -> list[tuple[str, str, str]]:
    try:
        doc = json.loads(lock.read_text())
    except (OSError, ValueError) as e:
        raise CollectorError(f"{lock}: {e}") from e
    packages = doc.get("packages")
    if not isinstance(packages, dict) or not packages:
        # Empty is a truncated or hand-made lock, never "no dependencies": npm writes the root
        # package entry ("") even for a dependency-free project.
        raise CollectorError(f"{lock}: no `packages` map (lockfileVersion 2 or 3 expected)")
    out = []
    for path, entry in packages.items():
        if not path or not isinstance(entry, dict) or entry.get("dev") or not entry.get("version"):
            continue
        name = entry.get("name") or path.split("node_modules/")[-1]
        out.append(("npm", name, str(entry["version"])))
    return out


_PNPM_KEY = re.compile(r"^(@?[^@\s']+)@([^\s'(]+)")  # name@version, before any (peer) suffix


def _pnpm_section(lines: list[str], section: str) -> Iterator[tuple[int, str]]:
    """(indent, stripped line) for each line under one top-level section of a pnpm lock,
    blanks and comments skipped. Two-space indentation is the structure."""
    current = ""
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        if indent == 0:
            current = line.rstrip(":")
        elif current == section:
            yield indent, line


def _pnpm_roots(lines: list[str]) -> set[str]:
    """Each importer's `dependencies` entry (not dev or optional) as "name@version(peers)"."""
    roots: set[str] = set()
    block = ""    # dependencies | devDependencies | ... within an importer
    pending = ""  # a dependency name awaiting its version: line
    for indent, line in _pnpm_section(lines, "importers"):
        if indent == 4:
            block = line.rstrip(":")
            pending = ""
        elif indent == 6 and block == "dependencies":
            pending = line.rstrip(":").strip("'\"")
        elif indent == 8 and pending and line.startswith("version:"):
            roots.add(f"{pending}@{line.split(':', 1)[1].strip().strip(chr(39))}")
            pending = ""
    return roots


def _pnpm_edges(lines: list[str]) -> dict[str, set[str]]:
    """Snapshot key -> its dependencies' (and optional dependencies') "name@version(peers)"."""
    edges: dict[str, set[str]] = {}
    key = ""
    block = ""
    for indent, line in _pnpm_section(lines, "snapshots"):
        if indent == 2:
            key = line.rstrip(":").strip("'\"")
            if line.endswith("{}"):
                key = key.rstrip(": {}")
            edges.setdefault(key, set())
            block = ""
        elif indent == 4:
            block = line.rstrip(":")
        elif indent == 6 and block in ("dependencies", "optionalDependencies"):
            name, _, version = line.partition(":")
            edges[key].add(f"{name.strip().strip(chr(39))}@{version.strip().strip(chr(39))}")
    return edges


def pnpm_packages(lock: Path) -> list[tuple[str, str, str]]:
    """pnpm-lock.yaml v9 production set. The lock has no per-package dev flag: production is the
    closure of each importer's `dependencies` (not `devDependencies`/`optionalDependencies` of the
    importer itself) through the `snapshots` graph. Versions carry peer suffixes
    `1.2.3(react@19.0.0)`, which both the snapshot keys and the importer `version:` lines use, so
    edges are matched on the full string and the version reported is the part before `(`."""
    try:
        lines = lock.read_text().splitlines()
    except OSError as e:
        raise CollectorError(f"{lock}: {e}") from e
    edges = _pnpm_edges(lines)
    if not edges:
        raise CollectorError(f"{lock}: no `snapshots` section (pnpm lockfileVersion 9 expected)")
    seen: set[str] = set()
    todo = list(_pnpm_roots(lines))
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        todo.extend(edges.get(key, ()))
    return [("npm", m.group(1), m.group(2)) for m in map(_PNPM_KEY.match, seen) if m]


def cargo_packages(lock: Path) -> list[tuple[str, str, str]]:
    try:
        text = lock.read_text()
    except OSError as e:
        raise CollectorError(f"{lock}: {e}") from e
    blocks = text.split("[[package]]")[1:]
    if not blocks:
        # A Cargo.lock always lists the workspace's own package: none means truncated or empty.
        raise CollectorError(f"{lock}: no [[package]] blocks")
    out = []
    for block in blocks:
        name = re.search(r'^name = "([^"]+)"', block, re.M)
        version = re.search(r'^version = "([^"]+)"', block, re.M)
        if name and version:
            out.append(("crates.io", name.group(1), version.group(1)))
    return out


def osv(path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(f"{OSV_URL}{path}", data=json.dumps(body).encode() if body is not None else None, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, ValueError, TimeoutError) as e:
        raise CollectorError(f"OSV {path}: {e}") from e


def severity_of(vuln: dict) -> str:
    db = vuln.get("database_specific") or {}
    sev = str(db.get("severity") or "").upper()
    if sev in ORDER:
        return sev
    for s in vuln.get("severity") or []:
        score = str(s.get("score", ""))
        m = re.search(r"CVSS:[34]\.\d/.*", score)
        if not m:
            try:
                n = float(score)
            except ValueError:
                continue
            return "CRITICAL" if n >= 9 else "HIGH" if n >= 7 else "MODERATE" if n >= 4 else "LOW"
    return "UNKNOWN"


def locked_vulns(args: argparse.Namespace) -> dict[str, int]:
    """OSV over the locked production packages: the severity keys and the packages queried."""
    packages: list[tuple[str, str, str]] = []
    for p in args.uv:
        packages.extend(uv_packages(Path(p)))
    for f in args.npm_lock:
        packages.extend(npm_packages(Path(f)))
    for f in args.pnpm_lock:
        packages.extend(pnpm_packages(Path(f)))
    for f in args.cargo_lock:
        packages.extend(cargo_packages(Path(f)))
    packages = sorted(set(packages))
    # A lockfile with only dev dependencies (instalite's web/) has an empty production set:
    # that is the answer, zero exposure, not a broken source.
    if not packages:
        print("vuln: 0 locked production packages (dev-only lockfile): nothing to query", file=sys.stderr)
    hits: dict[str, set[tuple[str, str]]] = {}  # vuln id -> {(name, version)}
    for i in range(0, len(packages), BATCH) if packages else []:
        chunk = packages[i : i + BATCH]
        res = osv("/v1/querybatch", {"queries": [{"package": {"name": n, "ecosystem": eco}, "version": v} for eco, n, v in chunk]})
        for (eco, n, v), r in zip(chunk, res.get("results", [])):
            for vuln in r.get("vulns") or []:
                hits.setdefault(vuln["id"], set()).add((n, v))
    rows = []
    for vid in sorted(hits):
        rows.append((severity_of(osv(f"/v1/vulns/{vid}")), vid))
    counts = {s: 0 for s in ORDER}
    for sev, _ in rows:
        counts[sev] += 1
    for sev, vid in sorted(rows, key=lambda r: (ORDER.index(r[0]), r[1])):
        pk = ", ".join(f"{n}@{v}" for n, v in sorted(hits[vid]))
        print(f"vuln: {sev} {pk} {vid}", file=sys.stderr)
    print(f"vuln: {len(packages)} locked production packages, {len(rows)} vulnerabilities ({counts['CRITICAL']} critical, {counts['HIGH']} high)", file=sys.stderr)
    return {
        f"vuln.{args.scope}.critical": counts["CRITICAL"],
        f"vuln.{args.scope}.high": counts["HIGH"],
        f"vuln.{args.scope}.total": len(rows),
        f"vuln.{args.scope}.packages": len(packages),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scope", required=True)
    ap.add_argument("--uv", action="append", default=[], help="a uv project directory (uv.lock)")
    ap.add_argument("--npm-lock", action="append", default=[], help="a package-lock.json")
    ap.add_argument("--pnpm-lock", action="append", default=[], help="a pnpm-lock.yaml (v9)")
    ap.add_argument("--cargo-lock", action="append", default=[], help="a Cargo.lock")
    ap.add_argument("--compose", action="extend", nargs="+", default=[], metavar="FILE", help="compose files (image references)")
    ap.add_argument("--out", help="write the JSON here (default: stdout)")
    args = ap.parse_args()
    locked = bool(args.uv or args.npm_lock or args.pnpm_lock or args.cargo_lock)
    if not (locked or args.compose):
        ap.error("at least one of --uv, --npm-lock, --pnpm-lock, --cargo-lock, --compose")
    out: dict[str, int] = {}
    try:
        if args.compose:
            out.update(compose_images(args.compose, args.scope))
        if locked:
            out.update(locked_vulns(args))
    except CollectorError as e:
        print(f"vuln: {e}", file=sys.stderr)
        return EXIT_USAGE
    text = json.dumps(out, indent=2) + "\n"
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
