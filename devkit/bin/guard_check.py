#!/usr/bin/env python3
"""Guard kit: a repo's code-structure rules as data, judged by one devkit mechanism.

Every repo hand-rolled its structure guards as test files (a source walk, a predicate, an
allow-list whose stale entries must fail, fixture self-tests). Here the walk, the predicates
(bin/_guard_rules.py) and their self-tests (tests/guard_check_test.py) are devkit's; the rules
and their parameters are the repo's `scripts/ci/guards.conf`
(standardization/guard-kit-design.md). A repo writes no test for a rule it declares.

Usage, from the repo root:
  guard_check.py [--conf scripts/ci/guards.conf] [--section NAME ...] [--metrics-out FILE]

Conf: the section keys of layers.conf (bin/_source_tree.py: lang, root, src, exclude, alias;
lang compose too, whose section takes only the compose-* rules and reads the compose files
under src through bin/_compose.py, stdlib only), then rule lines, then `known` lines; `#` comments carry each rule's why. Globs are relative to
the section's root, and a glob also names a directory the file is under.

  only-import MODULE[,MODULE] GLOB...           only files under the globs import these
  ban-import  GLOB... MODULE[:NAME,NAME] [except GLOB[:NAME,NAME]...]
                                                files under the globs do not import the module,
                                                or those names from it
  only-call   NAME GLOB...                      only files under the globs call NAME
  ban-call    NAME[,NAME] GLOB... [except GLOB...]
                                                files under the globs do not call NAME. Both
                                                match NAME against the callee exactly as the
                                                call site writes it and follow no import:
                                                after `from flask import request`, write
                                                `request.get_json`; `flask.request.get_json`
                                                matches nothing (orbit #112)
  call-arg-ban CALLEE[,CALLEE] ARG-SHAPE[,ARG-SHAPE] GLOB... [except GLOB...]
                                                files under the globs pass no argument of
                                                these shapes to these callees, at any depth of
                                                the argument list (`log.* String(err)`)
  logger-name PREFIX [except GLOB...]           python: every logger is PREFIX or PREFIX.<x>,
                                                nothing logs on the root logger
  outbound-timeout [except GLOB...]             python: every outbound HTTP call has a timeout
  utc-today   [except GLOB...]                  python: no date.today(), datetime.utcnow(), or
                                                datetime.now() without a tz
  single-writer ATTR GLOB...                    python: only files under the globs write .ATTR,
                                                by assignment, setattr or the Django ORM
                                                (`ATTR=` to update/create/get_or_create/
                                                update_or_create, their defaults= keys,
                                                bulk_update fields, bulk_create's Model(ATTR=))
  single-writer TABLE[.FIELD] GLOB[:FUNCTION,FUNCTION]...
                                                ts: only files under the globs (only those
                                                top-level functions of them) write the drizzle
                                                table, or with FIELD set that column in an
                                                `.update(TABLE).set({...})`
  own-transaction GLOB[:FUNCTION,FUNCTION]...   ts: only files under the globs (only those
                                                top-level functions of them) open or end a
                                                transaction: `.transaction(`, `.commit(`,
                                                `.rollback(` on any receiver, a literal BEGIN/
                                                COMMIT/ROLLBACK (own_commit_check.py's rule)
  only-text   PATTERN GLOB...                   only files under the globs spell PATTERN, a
                                                substring or /REGEX/ of the code text (comments
                                                blanked, strings kept); quote one holding a
                                                space or `#` ("for: x"), and name it with @NAME
  scoped-exports GLOB PARAM[,PARAM] [marker TEXT] [except GLOB...]
                                                every exported (ts) / public module-level
                                                (python) function under GLOB declares one of
                                                the params and uses it, unless its leading
                                                comment (ts) / docstring (python) holds TEXT
  calls-one-of GLOB NAME[,NAME] [depth N] [functions-only] [server-only]
               [except GLOB[:EXPORT,EXPORT]...]
                                                ts: every export of a module under GLOB calls
                                                one of NAMEs, itself or through module-local
                                                helpers N deep (default 1); a value export is
                                                judged by its initializer unless
                                                functions-only skips it; server-only judges
                                                only "use server" modules
  decorated-with GLOB DECORATOR[,DECORATOR] [when DECORATOR[,DECORATOR]]
               [except GLOB[:FUNCTION,FUNCTION]...]
                                                python: every function under GLOB carrying a
                                                `when` decorator (any depth), or without
                                                `when` every public module-level function,
                                                also carries one of DECORATORs; names match
                                                as written on a dotted suffix (`post` names
                                                `router.post`)
  compose-healthcheck    [except GLOB[:SERVICE,SERVICE]...]
                                                compose: every service with an `image:` or
                                                `build:` declares a healthcheck (a block with
                                                no `test` keeps the image's own; `disable:
                                                true` or test NONE is none)
  compose-pinned-image   [except GLOB[:SERVICE,SERVICE]...]
                                                compose: every `image:` has a digest or a tag
                                                other than `latest` (`${VAR:-d}` reads as d;
                                                a variable with no default is the .env's pin)
  compose-no-privileged  [except GLOB[:SERVICE,SERVICE]...]
                                                compose: no service sets `privileged: true`
  compose-restart-policy [except GLOB[:SERVICE,SERVICE]...]
                                                compose: every service declares `restart:` or
                                                `deploy.restart_policy` (`"no"` is a choice)
  known       PATH RULE-ID COUNT REASON         COUNT violations of the rule in PATH are debt
                                                being paid down: shrink-only

Any rule line may start with `@NAME`, its id; otherwise the id is its kind and its subject:
the first argument of only-import/only-call/ban-call/call-arg-ban/logger-name/single-writer/
only-text (whose PATTERN with a space has no id but its @NAME), none for own-transaction,
the module of ban-import, the second argument of scoped-exports/calls-one-of/decorated-with
(`ban-import:sqlalchemy:select`, `only-call:fetch`, `outbound-timeout`). `known` lines and
the output name rules by id, so two rules of one kind and subject need a name. `except` names the sanctioned sites inside a ban (design, kept); a
rule whose globs ARE its sites (only-*, single-writer, own-transaction) takes none: a TS
single-writer's or own-transaction's `GLOB:FUNCTION` owner narrows a site to those functions
instead. On ban-import,
`except GLOB:NAME,NAME` sanctions only those of the banned names there (a cron module may
bind select and update, still not text); on calls-one-of and decorated-with it sanctions
those exports or functions there (`except src/app/api/health:GET`), which replaces the seed
tests' `file#name` allow-lists. Each NAME of such a site must still fire (an owner function
must still write), or it is stale.
Debt goes in `known`.

Matching, for the import and call rules (the semantic rules' shapes are bin/_guard_rules.py's):
  - MODULE is a prefix on segment boundaries: `sqlalchemy` holds `sqlalchemy.orm` (python),
    `drizzle-orm` holds `drizzle-orm/pg-core` (ts), never `sqlalchemy_utils`. Python reads
    metrics/python.py's runtime imports (relative imports resolved; `if TYPE_CHECKING:`
    erased; imports inside functions counted). TS reads bin/_ts_lex.py's runtime imports
    (type-only imports erased); a relative or aliased specifier resolves to its root-relative
    path without extension or `/index` (`@/lib/db`, `../lib/db.js` -> `src/lib/db`), and the
    conf names our own modules the same way (`@/lib/db` or `src/lib/db`).
  - `MODULE:NAME,...` fires only when a listed name is bound from the module: `from M import
    NAME`, `import { NAME } from 'M'`, a re-export of it; a default import binds `default`.
    `import M`, a namespace, dynamic or side-effect import binds no name, so pair the ban
    with `ban-call M.NAME` when that spelling matters. The names follow the first colon
    that is not a TS specifier scheme's (`node:`, `bun:`): `node:http` bans the module,
    `node:http:STATUS_CODES` that name from it.
  - NAME is the callee exactly as written, dotted (`fetch`, `requests.get`, `db.execute`):
    `prefetch(`, `x.fetchQuery(` and `api.fetch(` are not calls to `fetch`, and neither is a
    callee hanging off an expression (`client().fetch(`). TS also counts `new NAME(` and
    `NAME<T>(`; declarations and keywords are not calls (bin/_ts_lex.py header). The python
    semantic rules resolve a callee through the file's imports instead (`dt.now()` after
    `from datetime import datetime as dt` is datetime.datetime.now).
  - call-arg-ban's CALLEE matches as written on a dotted suffix (`log.error` names
    `this.log.error`), and `RECEIVER.*` names any method of the receiver (`logger.*`: every
    `logger.<m>(`). A segment may be `/REGEX/`, searched against that one name (no comma, no
    `/`): `/^(log|.+Log)$/.*`. A logger is seen only by the variable it is bound to, so bind
    each `const log = logger("domain")` and name `log.*`; the regex is for a repo that did
    not. ARG-SHAPE is a closed vocabulary, the identifier written `err` (the error names,
    bin/_guard_rules.py ERROR_NAMES) or `/REGEX/` (searched; no comma): `String(err)` and
    `${err}` (ts; the interpolation is the identifier alone), `str(err)`, `repr(err)` and
    f-string `{err}` (python), `err.message`, `err.stack` and bare `err`, a whole argument that
    is the name alone (both; python: positional only). One violation per call.

A rule with no candidates is inert, not an error: when none of a ban's globs matches a scanned
file, or a calls-one-of or decorated-with filter (`server-only`, `when`, `functions-only`)
leaves no function to judge in any file, it passes with one `<conf>:<line>: <rule>: inert: no
files match <glob>` (or `inert: no <unit> under <glob>`) line on every run, so a scaffold can
ship a rule live before the app has its first server action (devkit #121 shipped
`@action-request-id` commented out because this was exit 2). A `known` line for an inert rule is
still stale. What stays exit 2 is a rule that is wrong rather than early: one of a ban's
several globs matching nothing while another matches (a renamed directory), and a sanctioned
site (an only-*/single-writer glob, an `except` glob) of a rule with candidates that matches no
scanned file. Every scanned file must parse
(python: ast; ts: the lexer ends where it started), and scoped-exports and calls-one-of cannot
judge a TS file in their scope that re-exports (`export * from`, `export { f } from`, an
imported name exported): exit 2, as rollcall's walker failed loudly.
A ts tree scans `.vue`/`.svelte` components by their top-level `<script>` blocks, lines as in
the file (bin/_source_tree.py sfc_scripts); a template is not code to any rule, so a template
`@click="client.get()"` is not seen.
A sanctioned site (an only-*/single-writer glob, an `except` glob) under which nothing fires
any more is a stale exception and fails like a stale `known` line, as the allow-lists of the
repo tests this replaces did (finplat fetch.guard "every allowlisted file still needs its
exception").

`known` counts per file and rule, with no line numbers, so an edit above a site costs no conf
fix (layers.conf's PATH -> PATH principle). More violations in the file than COUNT fail, every
site listed; fewer fail as stale, naming the count to write (or the line to delete). Growth is
the ratchet's: `--metrics-out` writes `guards.<section>.known`, the violations that fire
(listed ones included; equal to the known COUNTs once the check passes; direction lower,
tolerance 0), so a new or raised `known` line needs the metrics-rebaseline label.

Output (an API): one `<root>/<path>:<line>: <rule>: ...` or `<conf>:<line>: ...` line per
problem, then per section one `GUARD <section> <rule> ok|FAIL <n> known=<k>` line per rule
(n = violations that fire, k = its known COUNTs; an inert rule is `ok 0`, after its inert line)
and one `guards <section> files=<n>
violations=<n> known=<k>` line, then `guard_violations=<n>` (all sections). Exit: 0 ok,
1 violations, stale known lines or stale sites, 2 a bad call, a malformed conf, a file that does
not parse or cannot be judged, or a rule with a vacuous glob.
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import posixpath
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType

EXIT_OK = 0
EXIT_PROBLEMS = 1
EXIT_USAGE = 2

DEFAULT_CONF = "scripts/ci/guards.conf"
IMPORT_RULES = ("only-import", "ban-import")
CALL_RULES = ("only-call", "ban-call")
CALLEE = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*")
PY_MODULE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*")
IDENTIFIER = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
TABLE_FIELD = re.compile(rf"{IDENTIFIER.pattern}(\.{IDENTIFIER.pattern})?")
RULE_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_.-]*")
# The specifier schemes a TS runtime resolves itself (`node:http`, `bun:test`). The colon after
# one belongs to the module, so a ban-import subject's names follow the next colon
# (`node:http:STATUS_CODES`). A Python module never holds a colon; nor does an npm package name.
TS_SCHEMES = ("node", "bun")


def _load_source_tree() -> ModuleType:
    """bin/_source_tree.py by path (`python3 -I` keeps this directory off sys.path); it loads
    metrics/python.py, the TS lexer and the rule predicates the same way."""
    path = Path(__file__).resolve().parent / "_source_tree.py"
    spec = importlib.util.spec_from_file_location("devkit_source_tree", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"guard_check ERROR: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.dont_write_bytecode = True  # no __pycache__ in a consumer's vendored devkit/
    spec.loader.exec_module(module)
    return module


tree = _load_source_tree()
rules = tree.load("bin/_guard_rules.py", "devkit_guard_rules")
ConfError = tree.ConfError
PY_ONLY = ("python",)
TS_ONLY = ("ts",)
COMPOSE_ONLY = ("compose",)
# A compose service name, as an `except GLOB:SERVICE` names it (compose allows `.` and `-`).
SERVICE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


@dataclass(frozen=True)
class Kind:
    shape: str
    langs: tuple[str, ...]
    sited: bool  # its globs are the sanctioned sites (only-*, single-writer), not a ban's scope
    arity: tuple[int, int | None]  # how many arguments before the options and `except` (min, max)
    act: str = ""  # what a sanctioned site does ("import"), for the messages; "": fire the rule
    # The options that may follow the arguments, each with its value's metavar ("": a flag).
    options: tuple[tuple[str, str], ...] = ()
    # What `except GLOB:NAME` names, as the stale message says it ("imports {names}");
    # "": the kind takes no per-name except.
    named: str = ""
    # A unit rule judges functions, not files: no function selected in any file is vacuous.
    units: bool = False
    # A violation is a construct the globs forbid ("banned under"), not one they require.
    forbids: bool = False
    # What a stale site no longer does, when "<act>s it" does not read (own-transaction).
    stale_as: str = ""

    @property
    def stale(self) -> str:
        if self.stale_as:
            return self.stale_as
        return f"{self.act}s it" if self.act else "fires the rule"


KINDS = {
    "only-import": Kind("only-import MODULE[,MODULE] GLOB...", tree.LANGS, True, (2, None), "import"),
    "ban-import": Kind(
        "ban-import GLOB... MODULE[:NAME,NAME] [except GLOB[:NAME,NAME]...]",
        tree.LANGS,
        False,
        (2, None),
        "import",
        named="imports {names}",
        forbids=True,
    ),
    "only-call": Kind("only-call NAME GLOB...", tree.LANGS, True, (2, None), "call"),
    "ban-call": Kind(
        "ban-call NAME[,NAME] GLOB... [except GLOB...]",
        tree.LANGS,
        False,
        (2, None),
        "call",
        forbids=True,
    ),
    # No `act`: a stale except means nothing there passes the shapes any more, not that nothing
    # calls the logger.
    "call-arg-ban": Kind(
        "call-arg-ban CALLEE[,CALLEE] ARG-SHAPE[,ARG-SHAPE] GLOB... [except GLOB...]",
        tree.LANGS,
        False,
        (3, None),
        forbids=True,
    ),
    "logger-name": Kind("logger-name PREFIX [except GLOB...]", PY_ONLY, False, (1, 1)),
    "outbound-timeout": Kind("outbound-timeout [except GLOB...]", PY_ONLY, False, (0, 0)),
    "utc-today": Kind("utc-today [except GLOB...]", PY_ONLY, False, (0, 0)),
    "single-writer": Kind(
        "single-writer ATTR|TABLE[.FIELD] GLOB[:FUNCTION,FUNCTION]...",
        tree.LANGS,
        True,
        (2, None),
        "write",
        named="writes it in {names}",
    ),
    "only-text": Kind("only-text PATTERN GLOB...", tree.LANGS, True, (2, None), "spell"),
    "own-transaction": Kind(
        "own-transaction GLOB[:FUNCTION,FUNCTION]...",
        TS_ONLY,
        True,
        (1, None),
        "open or end a transaction",
        named="opens or ends one in {names}",
        stale_as="opens or ends a transaction",
    ),
    "scoped-exports": Kind(
        "scoped-exports GLOB PARAM[,PARAM] [marker TEXT] [except GLOB...]",
        tree.LANGS,
        False,
        (2, 2),
        options=(("marker", "TEXT"),),
    ),
    "calls-one-of": Kind(
        "calls-one-of GLOB NAME[,NAME] [depth N] [functions-only] [server-only] "
        "[except GLOB[:EXPORT,EXPORT]...]",
        TS_ONLY,
        False,
        (2, 2),
        options=(("depth", "N"), ("functions-only", ""), ("server-only", "")),
        named="exports {names} without the call",
        units=True,
    ),
    "decorated-with": Kind(
        "decorated-with GLOB DECORATOR[,DECORATOR] [when DECORATOR[,DECORATOR]] "
        "[except GLOB[:FUNCTION,FUNCTION]...]",
        PY_ONLY,
        False,
        (2, 2),
        options=(("when", "DECORATOR[,DECORATOR]"),),
        named="defines {names} without the decorator",
        units=True,
    ),
    # The compose rules judge services: `except GLOB:SERVICE,...` sanctions those services of
    # that file, and each must still fire.
    "compose-healthcheck": Kind(
        "compose-healthcheck [except GLOB[:SERVICE,SERVICE]...]", COMPOSE_ONLY, False, (0, 0),
        named="defines {names} without a healthcheck", units=True,
    ),
    "compose-pinned-image": Kind(
        "compose-pinned-image [except GLOB[:SERVICE,SERVICE]...]", COMPOSE_ONLY, False, (0, 0),
        named="runs {names} on an unpinned image", units=True,
    ),
    "compose-no-privileged": Kind(
        "compose-no-privileged [except GLOB[:SERVICE,SERVICE]...]", COMPOSE_ONLY, False, (0, 0),
        named="runs {names} privileged", units=True, forbids=True,
    ),
    "compose-restart-policy": Kind(
        "compose-restart-policy [except GLOB[:SERVICE,SERVICE]...]", COMPOSE_ONLY, False, (0, 0),
        named="defines {names} without a restart policy", units=True,
    ),
}  # fmt: skip
COMPOSE_RULES = {
    "compose-healthcheck": rules.compose_healthcheck,
    "compose-pinned-image": rules.compose_pinned_image,
    "compose-no-privileged": rules.compose_no_privileged,
    "compose-restart-policy": rules.compose_restart_policy,
}
# The kinds whose first argument is the one GLOB they judge and whose second is the subject.
GLOB_FIRST = ("scoped-exports", "calls-one-of", "decorated-with")


# ------------------------------------------------------------------------------------ conf


@dataclass(frozen=True)
class Site:
    """A sanctioned site: an only-*/single-writer glob, or an `except` glob of a ban (on
    ban-import, optionally only for some of the banned names; empty: all of them)."""

    glob: str
    names: frozenset[str] = frozenset()

    def __str__(self) -> str:
        return f"{self.glob}:{','.join(sorted(self.names))}" if self.names else self.glob


@dataclass(frozen=True)
class Rule:
    kind: str
    id: str
    targets: tuple[str, ...]  # modules, callees, the prefix, the attribute or the params
    names: frozenset[str]  # ban-import MODULE:NAME,...; empty: the module itself
    globs: tuple[str, ...]  # sited kinds: the sanctioned sites' globs; bans: where the ban applies
    excepts: tuple[Site, ...]
    line: int
    owners: tuple[Site, ...] = ()  # sited kinds: the globs as sites (single-writer GLOB:FUNCTION)
    marker: str = ""  # scoped-exports
    depth: int = 1  # calls-one-of: module-local helper levels followed (rollcall's localCallees)
    functions_only: bool = False  # calls-one-of: skip an exported value that is not a function
    server_only: bool = False  # calls-one-of: judge only "use server" modules
    when: tuple[str, ...] = ()  # decorated-with: the decorators that select a function
    shapes: tuple[rules.ArgShape, ...] = ()  # call-arg-ban
    callees: tuple[rules.CalleePattern, ...] = ()  # call-arg-ban: targets, compiled
    texts: tuple[rules.TextPattern, ...] = ()  # only-text: its one PATTERN, compiled

    @property
    def spec(self) -> Kind:
        return KINDS[self.kind]

    @property
    def unit(self) -> str:
        """What a unit rule judges, for the vacuous message."""
        if self.kind in COMPOSE_RULES:
            return {"compose-healthcheck": "service with an image or build",
                    "compose-pinned-image": "service with an image"}.get(self.kind, "service")  # fmt: skip
        if self.kind == "decorated-with":
            if not self.when:
                return "public function"
            return f"function decorated with {','.join(self.when)}"
        noun = "exported function" if self.functions_only else "export"
        return f'{noun} of a "use server" module' if self.server_only else noun

    @property
    def sites(self) -> tuple[Site, ...]:
        return self.owners if self.spec.sited else self.excepts

    def scopes(self, path: str) -> bool:
        """Whether the rule judges the file: a sited rule judges every file (its sites are
        sanctioned, the rest violate), a ban the files under its globs (all, with none)."""
        if self.spec.sited or not self.globs:
            return True
        return any(tree.matches(path, glob) for glob in self.globs)


@dataclass(frozen=True)
class Known:
    path: str
    rule: str
    count: int
    line: int


@dataclass
class Section(tree.SourceTree):
    rules: list[Rule] = field(default_factory=list)
    known: list[Known] = field(default_factory=list)


def parse_conf(path: Path) -> list[Section]:
    sections = tree.parse_sections(path, Section, _directive)
    for section in sections:
        _validate(section, path)
    return sections


def _directive(section: Section, tokens: list[str], where: str, lineno: int) -> None:
    name = ""
    if tokens[0].startswith("@"):
        name = tokens[0][1:]
        if RULE_NAME.fullmatch(name) is None:
            raise ConfError(f"{where}: a rule name is `@NAME`, NAME [A-Za-z][A-Za-z0-9_.-]*")
        tokens = tokens[1:]
        if not tokens or tokens[0] not in KINDS:
            raise ConfError(f"{where}: `@{name}` names the rule that follows it on its line")
    word, args = tokens[0], tokens[1:]
    if word == "known":
        section.known.append(_known(args, where, lineno, section))
    elif word in KINDS:
        if not section.lang:
            # ban-import reads its subject by the language (TS_SCHEMES).
            raise ConfError(f"{where}: a rule line comes after the section's `lang`")
        rule = _rule(word, name, args, where, lineno, section.lang)
        if any(r.id == rule.id for r in section.rules):
            raise ConfError(
                f"{where}: duplicate rule {rule.id}; merge their globs or name one with @NAME"
            )
        section.rules.append(rule)
    else:
        raise ConfError(f"{where}: unknown directive {word!r}")


def _split(values: str, where: str, what: str) -> tuple[str, ...]:
    parts = tuple(values.split(","))
    if "" in parts:
        raise ConfError(f"{where}: an empty entry in {what}")
    return parts


def _excepts(kind: str, args: list[str], names: frozenset[str], where: str) -> tuple[Site, ...]:
    if KINDS[kind].sited:
        raise ConfError(
            f"{where}: {kind} lists its sites as its globs; `except` is for ban rules"
        )
    if not args:
        raise ConfError(f"{where}: `except` needs at least one glob")
    return tuple(_site(kind, arg, names, where, "except ") for arg in args)


def _site(kind: str, arg: str, names: frozenset[str], where: str, said: str) -> Site:
    """One sanctioned site, `GLOB` or `GLOB:NAME,NAME` where the kind names its sites' units:
    a ban's `except` (said: "except ") or a single-writer's owner glob (said: "")."""
    glob, colon, listed = arg.partition(":")
    if not colon:
        return Site(glob)
    if not KINDS[kind].named or (kind == "ban-import" and not names):
        raise ConfError(
            f"{where}: `{said}GLOB:NAME` is for a ban-import of names, calls-one-of, "
            "decorated-with, a compose rule's services or a ts single-writer's or "
            "own-transaction's owners"
        )
    excused = frozenset(_split(listed, where, arg))
    if kind == "ban-import" and not excused <= names:
        stray = ", ".join(sorted(excused - names))
        raise ConfError(f"{where}: {said}{arg}: {stray} is not banned by this rule")
    shape = SERVICE if kind in COMPOSE_RULES else IDENTIFIER
    for name in excused:
        if shape.fullmatch(name) is None:
            raise ConfError(f"{where}: {said}{arg}: {name!r} is not a name")
    return Site(glob, excused)


def _options(kind: str, main: list[str], where: str) -> tuple[list[str], dict[str, str]]:
    """Split a rule's arguments from the options that follow them (`marker TEXT`, `depth N`,
    a flag); every word after the first option is an option or its value."""
    allowed = dict(KINDS[kind].options)
    at = next((i for i, word in enumerate(main) if word in allowed), len(main))
    found: dict[str, str] = {}
    rest = main[at:]
    while rest:
        word, rest = rest[0], rest[1:]
        if word not in allowed:
            shape = KINDS[kind].shape
            raise ConfError(f"{where}: {word!r} follows the options; expected `{shape}`")
        if word in found:
            raise ConfError(f"{where}: `{word}` given twice")
        metavar = allowed[word]
        if metavar:
            if not rest or rest[0] in allowed:
                raise ConfError(f"{where}: `{word}` takes one {metavar}")
            found[word], rest = rest[0], rest[1:]
        else:
            found[word] = ""
    return main[:at], found


def _ban_subject(subject: str, lang: str, where: str) -> tuple[str, frozenset[str]]:
    """ban-import's MODULE[:NAME,...]: the names follow the first colon that is not a TS
    specifier scheme's, so `node:http` is the module and `node:http:STATUS_CODES` its name."""
    scheme, colon, rest = subject.partition(":")
    head, tail = ("", subject)
    if lang == "ts" and colon and scheme in TS_SCHEMES:
        head, tail = f"{scheme}:", rest
    module, colon, listed = tail.partition(":")
    if not module:
        raise ConfError(f"{where}: ban-import {subject!r} names no module")
    if not colon:
        return head + module, frozenset()
    names = frozenset(_split(listed, where, subject))
    for banned in names:
        if IDENTIFIER.fullmatch(banned) is None:
            raise ConfError(f"{where}: ban-import {subject}: {banned!r} is not a name")
    return head + module, names


@dataclass(frozen=True)
class _Subject:
    """A rule line's subject as its kind reads it: the text the rule id names, the globs
    after it, and what the rule targets."""

    text: str
    globs: tuple[str, ...]
    targets: tuple[str, ...]
    names: frozenset[str] = frozenset()  # ban-import's banned names
    callees: tuple[rules.CalleePattern, ...] = ()  # call-arg-ban's


def _subject(kind: str, main: list[str], name: str, lang: str, where: str) -> _Subject:
    if kind == "ban-import":
        module, names = _ban_subject(main[-1], lang, where)
        return _Subject(main[-1], tuple(main[:-1]), (module,), names)
    if kind == "call-arg-ban":
        targets = _split(main[0], where, main[0])
        try:
            callees = tuple(rules.callee_pattern(pattern) for pattern in targets)
        except ValueError as exc:
            raise ConfError(f"{where}: {exc}") from exc
        return _Subject(main[0], tuple(main[2:]), targets, callees=callees)
    if kind in GLOB_FIRST:
        targets = _split(main[1], where, main[1])
        for target in targets:
            if kind == "scoped-exports" and IDENTIFIER.fullmatch(target) is None:
                raise ConfError(f"{where}: {target!r} is not a parameter name")
            dotted = PY_MODULE if kind == "decorated-with" else CALLEE
            if kind != "scoped-exports" and dotted.fullmatch(target) is None:
                raise ConfError(f"{where}: {target!r} is not a dotted name")
        return _Subject(main[1], (main[0],), targets)
    if kind == "own-transaction":
        return _Subject("", tuple(main), ())  # no subject: the rule is what it guards
    if kind == "only-text":
        if not name and re.search(r"\s", main[0]):
            raise ConfError(
                f"{where}: only-text {main[0]!r} holds a space, so it is no rule id; "
                "name the rule: `@NAME only-text ...`"
            )
        return _Subject(main[0], tuple(main[1:]), (main[0],))  # a comma is part of the text
    if not main:
        return _Subject("", (), ())
    return _Subject(main[0], tuple(main[1:]), _split(main[0], where, main[0]))


def _check_targets(kind: str, targets: tuple[str, ...], where: str) -> None:
    if kind == "only-call" and len(targets) > 1:
        raise ConfError(f"{where}: only-call takes one NAME; write one rule per callee")
    if kind in CALL_RULES:
        for callee in targets:
            if CALLEE.fullmatch(callee) is None:
                raise ConfError(f"{where}: {callee!r} is not a dotted name")
    if kind in ("single-writer", "logger-name") and len(targets) > 1:
        shape = KINDS[kind].shape
        raise ConfError(f"{where}: {kind} takes one {shape.split()[1]}; write one rule each")


def _check_single_writer(target: str, owners: tuple[Site, ...], lang: str, where: str) -> None:
    if lang == "python" and IDENTIFIER.fullmatch(target) is None:
        raise ConfError(f"{where}: {target!r} is not an attribute name")
    if lang == "python" and any(site.names for site in owners):
        raise ConfError(f"{where}: a python single-writer's owners are files, not functions")
    if lang == "ts" and TABLE_FIELD.fullmatch(target) is None:
        raise ConfError(f"{where}: {target!r} is not TABLE or TABLE.FIELD")


def _depth_and_when(options: dict[str, str], where: str) -> tuple[int, tuple[str, ...]]:
    depth = options.get("depth", "1")
    if not depth.isdigit():
        raise ConfError(f"{where}: `depth` takes the number of helper levels, not {depth!r}")
    when = _split(options["when"], where, "when") if "when" in options else ()
    for decorator in when:
        if PY_MODULE.fullmatch(decorator) is None:
            raise ConfError(f"{where}: when {decorator!r} is not a dotted name")
    return int(depth), when


def _patterns(
    kind: str, main: list[str], subject: str, lang: str, where: str
) -> tuple[tuple[rules.ArgShape, ...], tuple[rules.TextPattern, ...]]:
    """call-arg-ban's argument shapes and only-text's text pattern."""
    try:
        if kind == "call-arg-ban":
            return tuple(rules.arg_shape(s, lang) for s in _split(main[1], where, main[1])), ()
        if kind == "only-text":
            return (), (rules.text_pattern(subject),)
    except ValueError as exc:
        raise ConfError(f"{where}: {exc}") from exc
    return (), ()


def _rule(kind: str, name: str, args: list[str], where: str, lineno: int, lang: str) -> Rule:
    main = args[: args.index("except")] if "except" in args else args
    main, options = _options(kind, main, where)
    low, high = KINDS[kind].arity
    if len(main) < low or (high is not None and len(main) > high):
        raise ConfError(f"{where}: expected `{KINDS[kind].shape}`")
    subject = _subject(kind, main, name, lang, where)
    targets, names = subject.targets, subject.names
    _check_targets(kind, targets, where)
    owners = (
        tuple(_site(kind, g, names, where, "") for g in subject.globs) if KINDS[kind].sited else ()
    )
    if kind == "single-writer":
        _check_single_writer(targets[0], owners, lang, where)
    globs = tuple(site.glob for site in owners) or subject.globs
    excepts = (
        _excepts(kind, args[args.index("except") + 1 :], names, where) if "except" in args else ()
    )
    depth, when = _depth_and_when(options, where)
    shapes, texts = _patterns(kind, main, subject.text, lang, where)
    rule_id = name or (f"{kind}:{subject.text}" if subject.text else kind)
    return Rule(
        kind,
        rule_id,
        targets,
        names,
        globs,
        excepts,
        lineno,
        owners=owners,
        marker=options.get("marker", ""),
        depth=depth,
        functions_only="functions-only" in options,
        server_only="server-only" in options,
        when=when,
        shapes=shapes,
        callees=subject.callees,
        texts=texts,
    )


def _known(args: list[str], where: str, lineno: int, section: Section) -> Known:
    usage = "`known PATH RULE-ID COUNT REASON`"
    if args and re.fullmatch(r".+:\d+", args[0]):
        raise ConfError(f"{where}: {args[0]} names a line; a known line counts per file: {usage}")
    if len(args) < 4:
        raise ConfError(f"{where}: expected {usage}")
    path, rule, count = args[0], args[1], args[2]
    if not count.isdigit() or int(count) < 1:
        raise ConfError(f"{where}: COUNT {count!r} is not a positive number; expected {usage}")
    known = Known(path, rule, int(count), lineno)
    if any((k.path, k.rule) == (path, rule) for k in section.known):
        raise ConfError(f"{where}: duplicate known {path} {rule}; one line per file and rule")
    return known


def _validate(section: Section, path: Path) -> None:
    where = f"{path}:{section.line}: [{section.name}]"
    if not section.rules:
        raise ConfError(f"{where} has no rule")
    ids = {rule.id for rule in section.rules}
    for known in section.known:
        if known.rule not in ids:
            raise ConfError(
                f"{path}:{known.line}: known names {known.rule}, not a rule of [{section.name}]"
            )
    for rule in section.rules:
        if section.lang not in rule.spec.langs:
            langs = " or ".join(rule.spec.langs)
            raise ConfError(f"{path}:{rule.line}: {rule.kind} is for lang {langs}")
        if rule.kind not in IMPORT_RULES:
            continue
        for module in rule.targets:
            if section.lang == "python" and PY_MODULE.fullmatch(module) is None:
                raise ConfError(f"{path}:{rule.line}: {module!r} is not a dotted module")
            if section.lang == "ts" and module.startswith("."):
                raise ConfError(
                    f"{path}:{rule.line}: {module!r} is relative; name our own module by its "
                    "alias or its root-relative path"
                )


# ----------------------------------------------------------------------------------- files


def _canonical(callee: str | None, bindings: dict[str, str]) -> str | None:
    if callee is None:
        return None
    head, dot, rest = callee.partition(".")
    return bindings[head] + dot + rest if head in bindings else callee


def python_file(section: Section, root: Path, rel: str) -> rules.PyFile:
    metrics = tree.python_metrics()
    source = tree.read_source(root, rel)
    try:
        parsed = ast.parse(source, filename=rel)
    except SyntaxError as exc:
        raise ConfError(f"cannot parse {section.display}/{rel}: {exc}") from exc
    module = metrics.module_name(Path(rel))
    package = metrics.package_of(module, Path(rel).name == "__init__.py")
    imports = []
    bindings: dict[str, str] = {}  # local name -> what it is bound to (`dt` -> datetime.datetime)
    for node in metrics.runtime_imports(parsed):
        if isinstance(node, ast.Import):
            for a in node.names:
                imports.append(rules.Imported(a.name, frozenset(), node.lineno))
                head = a.name.split(".")[0]
                bindings[a.asname or head] = a.name if a.asname else head
            continue
        base = metrics.from_base(node, package)
        bound = frozenset(a.name for a in node.names if a.name != "*")
        imports.append(rules.Imported(base, bound, node.lineno))
        # `from pkg import sub` loads pkg.sub when sub is a module: a rule on pkg.sub sees it.
        imports.extend(rules.Imported(f"{base}.{n}", frozenset(), node.lineno) for n in bound)
        for a in node.names:
            if a.name != "*":
                bindings[a.asname or a.name] = f"{base}.{a.name}"
    calls = []
    for node in ast.walk(parsed):
        if isinstance(node, ast.Call):
            callee = metrics.dotted_name(node.func)
            calls.append(rules.PyCall(node, callee, _canonical(callee, bindings), node.lineno))
    return rules.PyFile(parsed, imports, calls, source)


def compose_file(section: Section, root: Path, rel: str) -> rules.ComposeFile:
    compose = tree.compose()
    try:
        return rules.ComposeFile(compose.services(root / rel, f"{section.display}/{rel}"))
    except (compose.YamlError, compose.ComposeError) as exc:
        raise ConfError(f"cannot read {exc}") from exc


def _ts_module(spec: str, importer: str, section: Section) -> str:
    """The name a TS import is matched by: a package as written, our own file root-relative
    without extension or `/index`."""
    base = tree.ts_local_base(spec, importer, section)
    if base is None:
        return spec
    stem, ext = posixpath.splitext(base)
    if ext in tree.TS_EXTS:
        base = stem
    return base[: -len("/index")] if base.endswith("/index") else base


def ts_file(section: Section, root: Path, rel: str) -> rules.TsFile:
    lex = tree.ts_lex()
    comments: list = []
    interpolations: list = []
    source = tree.read_source(root, rel)
    try:
        tokens = list(lex.tokenize(tree.ts_code(source, root / rel), comments, interpolations))
    except lex.LexError as exc:
        raise ConfError(f"cannot lex {section.display}/{rel}: {exc}") from exc
    imports = [
        rules.Imported(_ts_module(imp.spec, rel, section), imp.names, imp.line)
        for imp in lex.imports_in(tokens)
    ]
    calls = lex.calls_in(tokens)
    return rules.TsFile(tokens, comments, imports, calls, interpolations, source)


# ----------------------------------------------------------------------------------- check


def match_targets(rule: Rule, section: Section) -> tuple[str, ...]:
    """The rule's modules in the form an import is matched by: a TS alias of ours resolved as
    _ts_module resolves an import of it (a conf never writes a relative specifier)."""
    if section.lang == "python" or rule.kind not in IMPORT_RULES:
        return rule.targets
    return tuple(_ts_module(target, "", section) for target in rule.targets)


def fires(
    rule: Rule,
    targets: tuple[str, ...],
    section: Section,
    parsed: rules.PyFile | rules.TsFile | rules.ComposeFile,
) -> rules.Judged:
    """What the rule's predicate finds in one file, before sites and `known` are applied."""
    kind = rule.kind
    if kind in IMPORT_RULES:
        sep = "." if section.lang == "python" else "/"
        return rules.Judged(rules.import_hits(parsed.imports, targets, rule.names, sep))
    if kind in CALL_RULES:
        return rules.Judged(rules.call_hits(parsed.calls, targets))
    if kind == "calls-one-of":
        return rules.ts_calls_one_of(
            parsed, frozenset(targets), rule.depth, rule.functions_only, rule.server_only
        )
    if kind == "decorated-with":
        return rules.py_decorated_with(parsed, targets, rule.when)
    if kind in COMPOSE_RULES:
        return COMPOSE_RULES[kind](parsed)
    semantic: dict[str, Callable[[], list[rules.Hit]]] = {
        "logger-name": lambda: rules.logger_name(parsed, targets[0]),
        "outbound-timeout": lambda: rules.outbound_timeout(parsed),
        "utc-today": lambda: rules.utc_today(parsed),
        "single-writer": lambda: (
            rules.single_writer(parsed, targets[0])
            if section.lang == "python"
            else rules.ts_single_writer(parsed, *targets[0].partition(".")[::2])
        ),
        "only-text": lambda: rules.text_hits(parsed.code_text, rule.texts[0]),
        "own-transaction": lambda: rules.ts_own_transaction(parsed),
        "scoped-exports": lambda: (
            rules.py_scoped_exports if section.lang == "python" else rules.ts_scoped_exports
        )(parsed, frozenset(targets), rule.marker),
        "call-arg-ban": lambda: (
            rules.py_call_arg_ban if section.lang == "python" else rules.ts_call_arg_ban
        )(parsed, rule.callees, rule.shapes),
    }
    return rules.Judged(semantic[kind]())


def _sanctioned_by(rule: Rule) -> str:
    """The suffix a violation line names the rule's sites with."""
    excepts = f" (except {' '.join(map(str, rule.excepts))})" if rule.excepts else ""
    if rule.spec.sited:
        return f", which only {' '.join(map(str, rule.owners))} may {rule.spec.act}"
    if not rule.globs:
        return excepts
    return f", {'banned' if rule.spec.forbids else 'required'} under {' '.join(rule.globs)}{excepts}"


@dataclass
class Result:
    files: int = 0
    fired: dict[str, dict[str, list]] = field(default_factory=dict)  # rule id -> path -> hits
    problems: list[str] = field(default_factory=list)
    inert: list[str] = field(default_factory=list)  # one note per rule with no candidates
    failed: set[str] = field(default_factory=set)  # rule ids


def _apply_sites(rule: Rule, rel: str, hits: list, live: set[tuple[Site, str]]) -> list:
    """The hits that violate, after the rule's sanctioned sites (a sited rule's globs, a ban's
    excepts); marks live each site that excused something, as (site, "") or, per name it
    excused, (site, NAME). A site under which nothing fires is not live, so it reads stale."""
    here = [s for s in rule.sites if tree.matches(rel, s.glob)]
    left = []
    for hit in hits:
        whole = [s for s in here if not s.names]
        named = [s for s in here if s.names & hit.names]
        live.update((s, "") for s in whole)
        if whole:
            continue
        live.update((s, n) for s in named for n in s.names & hit.names)
        rest = hit.without(frozenset().union(*(s.names for s in named))) if named else hit
        if rest is not None:
            left.append(rest)
    return left


def _judge(rule: Rule, section: Section, files: list[str], parsed: dict, conf: Path, result: Result) -> None:
    targets = match_targets(rule, section)
    live: set[tuple[Site, str]] = set()
    violations: dict[str, list] = {}
    units = 0
    scoped = [rel for rel in files if rule.scopes(rel)]
    for rel in scoped:
        try:
            judged = fires(rule, targets, section, parsed[rel])
        except rules.Unjudgeable as exc:
            raise ConfError(f"{section.display}/{rel}: {rule.id} cannot judge it: {exc}") from exc
        units += judged.units or 0
        left = _apply_sites(rule, rel, judged.hits, live)
        if left:
            violations[rel] = left
    result.fired[rule.id] = violations
    listed = {k.path: k for k in section.known if k.rule == rule.id}
    inert = ""
    if not scoped:
        inert = f"no files match {' '.join(rule.globs)}"
    elif rule.spec.units and units == 0:
        inert = f"no {rule.unit} under {' '.join(rule.globs)}"
    if inert:
        result.inert.append(f"{conf}:{rule.line}: {rule.id}: inert: {inert}")
        _stale_known(rule, listed, violations, conf, result)
        return
    tail = _sanctioned_by(rule)
    for rel, hits in sorted(violations.items()):
        known = listed.get(rel)
        if known is not None and len(hits) <= known.count:
            continue
        over = f"; {len(hits)} fire in this file, known allows {known.count}" if known else ""
        for hit in hits:
            result.problems.append(
                f"{section.display}/{rel}:{hit.line}: {rule.id}: {hit.what}{tail}{over} "
                f"({conf}:{rule.line})"
            )
        result.failed.add(rule.id)
    for site in rule.sites:
        gone = sorted(n for n in site.names if (site, n) not in live)
        if (site.names and not gone) or (not site.names and (site, "") in live):
            continue
        verb = rule.spec.named.format(names=", ".join(gone)) if gone else rule.spec.stale
        fix = ", ".join(gone) if gone and len(gone) < len(site.names) else "the glob"
        result.problems.append(
            f"{conf}:{rule.line}: {rule.id}: nothing under {site.glob} {verb} any more, so "
            f"the exception is stale; delete {fix} from the rule"
        )
        result.failed.add(rule.id)
    _stale_known(rule, listed, violations, conf, result)


def _stale_known(rule: Rule, listed: dict, violations: dict[str, list], conf: Path, result: Result) -> None:
    for rel, known in sorted(listed.items()):
        now = len(violations.get(rel, []))
        if now >= known.count:
            continue
        fix = "delete the line" if now == 0 else f"write {now}"
        result.problems.append(
            f"{conf}:{known.line}: known {rel} {rule.id} {known.count}: {now} fire now; {fix}"
        )
        result.failed.add(rule.id)


def check_section(section: Section, repo: Path, conf: Path) -> Result:
    root = tree.tree_root(section, repo)
    walk, read = READERS[section.lang]
    files = walk(section, root)
    for rule in section.rules:
        scope = () if rule.spec.sited else rule.globs
        hit = {glob for glob in scope if any(tree.matches(f, glob) for f in files)}
        if scope and not hit:
            continue  # inert: no candidates, so no site to hold either (_judge notes it)
        for glob in (*rule.globs, *(s.glob for s in rule.excepts)):
            if glob not in hit and not any(tree.matches(f, glob) for f in files):
                raise ConfError(
                    f"{conf}:{rule.line}: {rule.id}: {glob} matches no scanned file of "
                    f"[{section.name}], so the rule checks nothing; fix the glob or delete it"
                )
    parsed = {rel: read(section, root, rel) for rel in files}  # every file parses, used or not
    result = Result(files=len(files))
    for rule in section.rules:
        _judge(rule, section, files, parsed, conf, result)
    return result


# Per section lang: the file walk and the parse every rule of the section reads.
READERS: dict[str, tuple[Callable, Callable]] = {
    "python": (tree.python_files, python_file),
    "ts": (tree.ts_files, ts_file),
    "compose": (tree.compose_files, compose_file),
}


def run(args: argparse.Namespace) -> int:
    conf = Path(args.conf)
    sections = parse_conf(conf)
    names = {s.name for s in sections}
    for wanted in args.section:
        if wanted not in names:
            raise ConfError(f"--section {wanted}: not in {conf}")
    chosen = [s for s in sections if not args.section or s.name in args.section]
    total = 0
    problems: list[str] = []
    summaries: list[str] = []
    metrics: dict[str, int] = {}
    inert: list[str] = []
    for section in chosen:
        result = check_section(section, Path.cwd(), conf)
        problems.extend(result.problems)
        inert.extend(result.inert)
        section_fired = 0
        for rule in section.rules:
            verdict = "FAIL" if rule.id in result.failed else "ok"
            known = sum(k.count for k in section.known if k.rule == rule.id)
            fired = sum(len(hits) for hits in result.fired[rule.id].values())
            section_fired += fired
            summaries.append(f"GUARD {section.name} {rule.id} {verdict} {fired} known={known}")
        total += section_fired
        metrics[f"guards.{section.name}.known"] = section_fired
        summaries.append(
            f"guards {section.name} files={result.files} violations={section_fired} "
            f"known={sum(k.count for k in section.known)}"
        )
    for line in (*problems, *inert):
        print(line)
    for line in summaries:
        print(line)
    print(f"guard_violations={total}")
    if args.metrics_out:
        out = Path(args.metrics_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return EXIT_PROBLEMS if problems else EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="guard_check.py",
        description="Fail the code-structure rules declared in guards.conf.",
    )
    parser.add_argument("--conf", default=DEFAULT_CONF, help=f"default: {DEFAULT_CONF}")
    parser.add_argument(
        "--section",
        action="append",
        default=[],
        metavar="NAME",
        help="check only this section (repeatable; default: all)",
    )
    parser.add_argument(
        "--metrics-out",
        metavar="FILE",
        help="write {guards.<section>.known: n} for metrics_collect.sh",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except ConfError as exc:
        print(f"guard_check ERROR: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
