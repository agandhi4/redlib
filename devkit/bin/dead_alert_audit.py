#!/usr/bin/env python3
"""Dead-alert audit: find vmalert rules that cannot fire, or would page without saying what to do.

Why (observability.md, Alerts): a rule that matches no series looks exactly like a healthy
app. finplat emitted `outcome="error"` while JobFailed matched `"failure"`, so the alert was
dead for months. The monthly review runs this over homelab's `stacks/homeinfra/vmalert/rules`
and fixes or deletes what it reports. It informs that review; it never gates.

Usage:
  dead_alert_audit.py --rules <dir-or-file ...> [--vm-url http://host:8428] [--since 30d]
                      [--runbook-required]

A directory contributes its `*.yml` and `*.yaml` files (not recursive). Recording rules are
skipped. Group-level `labels:` apply to every rule in the group, as in vmalert.

Static pass (always, no network):
  high    outcome-vocabulary         expr or labels match `outcome` on a value outside the
                                     fleet vocabulary `success|failure`
  medium  missing-severity           no `severity` label after merging group labels
  medium  missing-runbook            no `runbook` annotation (only with --runbook-required)
  medium  duplicate-name             the same alert name is defined in more than one file
Live pass (with --vm-url; one instant query per distinct alert name and selector):
  high    references-missing-metric  `absent_over_time(<selector>[<since>])` returns a series:
                                     a selector in the expr matched nothing in the window
  low     never-fired                `count_over_time(ALERTS{alertname=...}[<since>])` is empty.
                                     Relies on vmalert's -remoteWrite.url writing ALERTS into
                                     VictoriaMetrics. A quiet healthy app is also "never fired",
                                     so this is the review's question, not a verdict.

Selectors are found by a PromQL tokenizer, not a parser: identifiers not followed by `(` and
not keywords, with their `{...}` matchers. Bare `{...}` selectors count too.

YAML: a strict subset parser (block mappings and sequences, plain, quoted and block scalars,
comments), so the script runs under `python3 -I` with no PyYAML. Anchors, tags, flow
collections other than `[]`/`{}` and multi-document files are rejected with file:line.

Output: `dead-alert <high|medium|low> <alertname> <reason>` per finding on stdout, then
`dead_alert_audit: <n> findings over <m> alerts`. Progress lines go to stderr.

Exit codes: 0 audit ran (findings or not), 2 usage error, unreadable or malformed rule file,
or a live query that could not run. A failed live pass is an error rather than an empty
report, because "no findings" from an unreachable VictoriaMetrics would read as all-clear.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import TypeAlias

EXIT_OK = 0
EXIT_USAGE = 2

HIGH = "high"
MEDIUM = "medium"
LOW = "low"

FLEET_OUTCOMES = frozenset({"success", "failure"})
QUERY_TIMEOUT_SECONDS = 30.0
RULE_SUFFIXES = (".yml", ".yaml")
SINCE_RE = re.compile(r"(?:[0-9]+(?:ms|[smhdwy]))+")

# TypeAlias, not `type Node = …`: python3 3.11 is supported (ruff.toml target-version).
Node: TypeAlias = "str | list[Node] | dict[str, Node] | None"


class AuditError(Exception):
    """The audit could not run as asked: bad usage, a bad rule file, a failed query (exit 2)."""


def log(message: str) -> None:
    print(f"dead_alert_audit: {message}", file=sys.stderr)


# --- YAML subset -----------------------------------------------------------------------------

_KEY_RE = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_.\-/]*)[ \t]*:(?:[ \t]+(.*))?")
_BLOCK_SCALAR_RE = re.compile(r"([|>])([-+]?)")
_COMMENT_RE = re.compile(r"[ \t]+#.*")
_DOUBLE_QUOTE_ESCAPES = {
    '"': '"',
    "\\": "\\",
    "/": "/",
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "0": "\0",
    " ": " ",
}


def _is_sequence_item(content: str) -> bool:
    return content == "-" or content.startswith("- ")


def _strip_comment(text: str) -> str:
    if text.startswith("#"):
        return ""
    return _COMMENT_RE.sub("", text, count=1).rstrip()


def _fold(lines: list[str]) -> str:
    # `>` scalars: a line break between two text lines becomes a space; each blank line
    # becomes one newline. More-indented lines are not special-cased (no rule uses them).
    parts: list[str] = []
    for index, text in enumerate(lines):
        if index == 0:
            parts.append(text)
        elif text == "":
            parts.append("\n")
        elif lines[index - 1] == "":
            parts.append(text)
        else:
            parts.append(f" {text}")
    return "".join(parts)


class _YamlSubset:
    """Recursive descent over indentation. Rewrites a `- key: v` line in place so the
    mapping that starts on a sequence line parses like any other block mapping."""

    def __init__(self, text: str, source: str) -> None:
        self._lines = text.splitlines()
        self._source = source
        self._pos = 0

    def parse(self) -> Node:
        self._skip_document_start()
        first = self._peek()
        if first is None:
            return None
        if first[0] != 0:
            raise self._error("the document must start at column 0")
        node = self._block(0)
        if self._peek() is not None:
            raise self._error("unexpected indentation")
        return node

    def _skip_document_start(self) -> None:
        while self._pos < len(self._lines):
            content = self._lines[self._pos].strip()
            if content == "---":
                self._pos += 1
                return
            if content and not content.startswith("#"):
                return
            self._pos += 1

    def _error(self, message: str, line_index: int | None = None) -> AuditError:
        line = (self._pos if line_index is None else line_index) + 1
        return AuditError(f"{self._source}:{line}: {message}")

    def _peek(self) -> tuple[int, str] | None:
        """(indent, content) of the next line that is not blank or a comment."""
        while self._pos < len(self._lines):
            raw = self._lines[self._pos]
            content = raw.lstrip(" ")
            if content.startswith("\t"):
                raise self._error("tab indentation is not YAML")
            content = content.rstrip()
            if content and not content.startswith("#"):
                if content in ("---", "...") or content.startswith(("--- ", "%")):
                    raise self._error("multiple documents and directives are not supported")
                return len(raw) - len(raw.lstrip(" ")), content
            self._pos += 1
        return None

    def _block(self, indent: int) -> Node:
        line = self._peek()
        assert line is not None, "callers peek before descending"
        if _is_sequence_item(line[1]):
            return self._sequence(indent)
        return self._mapping(indent)

    def _sequence(self, indent: int) -> list[Node]:
        items: list[Node] = []
        while (line := self._peek()) is not None and line[0] >= indent:
            line_indent, content = line
            if line_indent > indent:
                raise self._error("unexpected indentation")
            if not _is_sequence_item(content):
                break
            rest = content[1:].lstrip(" ")
            if rest == "" or rest.startswith("#"):
                self._pos += 1
                items.append(self._nested(indent, allow_compact=False))
                continue
            inner = line_indent + len(content) - len(rest)
            if _is_sequence_item(rest) or _KEY_RE.fullmatch(_strip_comment(rest)):
                self._lines[self._pos] = " " * inner + rest
                items.append(self._block(inner))
                continue
            start = self._pos
            self._pos += 1
            items.append(self._inline(rest, indent, start))
        return items

    def _mapping(self, indent: int) -> dict[str, Node]:
        mapping: dict[str, Node] = {}
        while (line := self._peek()) is not None and line[0] >= indent:
            line_indent, content = line
            if line_indent > indent:
                raise self._error("unexpected indentation")
            if _is_sequence_item(content):
                raise self._error("a sequence item where a `key:` was expected")
            match = _KEY_RE.fullmatch(content)
            if match is None:
                raise self._error("expected `key: value`")
            key = match.group(1)
            if key in mapping:
                raise self._error(f"duplicate key `{key}`")
            start = self._pos
            self._pos += 1
            mapping[key] = self._value(match.group(2) or "", indent, start)
        return mapping

    def _nested(self, parent_indent: int, allow_compact: bool) -> Node:
        line = self._peek()
        if line is None:
            return None
        line_indent, content = line
        if line_indent > parent_indent:
            return self._block(line_indent)
        # `rules:` followed by `- alert:` at the key's own indent is valid YAML.
        if allow_compact and line_indent == parent_indent and _is_sequence_item(content):
            return self._sequence(line_indent)
        return None

    def _value(self, rest: str, indent: int, start: int) -> Node:
        text = _strip_comment(rest.strip())
        if text == "":
            return self._nested(indent, allow_compact=True)
        block = _BLOCK_SCALAR_RE.fullmatch(text)
        if block is not None:
            return self._block_scalar(indent, block.group(1), block.group(2))
        return self._inline(rest.strip(), indent, start)

    def _inline(self, text: str, indent: int, start: int) -> Node:
        if text[0] in "'\"":
            return self._quoted(text, start)
        if text[0] in "[{":
            if _strip_comment(text) in ("[]", "{}"):
                return [] if text[0] == "[" else {}
            raise self._error("flow collections are not supported; use block style", start)
        if text[0] in "&*!%@`|>":
            raise self._error(
                f"`{text[0]}` (anchor, alias, tag or reserved) is not supported", start
            )
        parts = [_strip_comment(text)]
        # A plain scalar may continue on more-indented lines (a long expr wrapped by hand).
        while (line := self._peek()) is not None and line[0] > indent:
            parts.append(_strip_comment(line[1]))
            self._pos += 1
        value = " ".join(part for part in parts if part)
        if ": " in value or value.endswith(":"):
            raise self._error("a plain scalar cannot contain `: `; quote it", start)
        return value

    def _quoted(self, text: str, start: int) -> str:
        quote = text[0]
        out: list[str] = []
        index = 1
        while index < len(text):
            char = text[index]
            if quote == "'" and char == "'":
                if text[index + 1 : index + 2] == "'":
                    out.append("'")
                    index += 2
                    continue
                return self._close_quote(text[index + 1 :], "".join(out), start)
            if quote == '"' and char == "\\":
                escaped = _DOUBLE_QUOTE_ESCAPES.get(text[index + 1 : index + 2])
                if escaped is None:
                    raise self._error("unsupported escape in a double-quoted scalar", start)
                out.append(escaped)
                index += 2
                continue
            if quote == '"' and char == '"':
                return self._close_quote(text[index + 1 :], "".join(out), start)
            out.append(char)
            index += 1
        raise self._error("unterminated quoted scalar (multi-line quotes are not supported)", start)

    def _close_quote(self, after: str, value: str, start: int) -> str:
        if _strip_comment(after.strip()) != "":
            raise self._error("text after a closing quote", start)
        return value

    def _block_scalar(self, indent: int, style: str, chomp: str) -> str:
        lines: list[str] = []
        content_indent: int | None = None
        while self._pos < len(self._lines):
            raw = self._lines[self._pos].rstrip()
            if raw.strip() == "":
                lines.append("")
                self._pos += 1
                continue
            current = len(raw) - len(raw.lstrip(" "))
            if content_indent is None:
                if current <= indent:
                    break
                content_indent = current
            elif current < content_indent:
                break
            lines.append(raw[content_indent:])
            self._pos += 1
        trailing = 0
        while lines and lines[-1] == "":
            lines.pop()
            trailing += 1
        if not lines:
            return ""
        body = "\n".join(lines) if style == "|" else _fold(lines)
        if chomp == "-":
            return body
        if chomp == "+":
            return body + "\n" * (trailing + 1)
        return body + "\n"


def parse_yaml(text: str, source: str) -> Node:
    return _YamlSubset(text, source).parse()


# --- Rules -----------------------------------------------------------------------------------


@dataclass(frozen=True)
class Alert:
    name: str
    expr: str
    labels: dict[str, str]
    annotations: dict[str, str]
    source: str


def _string_map(node: Node, where: str) -> dict[str, str]:
    if node is None:
        return {}
    if not isinstance(node, dict):
        raise AuditError(f"{where} must be a mapping")
    result: dict[str, str] = {}
    for key, value in node.items():
        if not isinstance(value, str):
            raise AuditError(f"{where}.{key} must be a string")
        result[key] = value
    return result


def _required_string(rule: dict[str, Node], key: str, where: str) -> str:
    value = rule.get(key)
    if not isinstance(value, str) or not value.strip():
        raise AuditError(f"{where} needs a non-empty `{key}`")
    return value


def load_alerts(path: Path) -> list[Alert]:
    source = str(path)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise AuditError(f"cannot read rule file {source}: {exc}") from exc
    doc = parse_yaml(text, source)
    if doc is None:
        return []
    if not isinstance(doc, dict) or "groups" not in doc:
        raise AuditError(f"{source}: the top level must be a mapping with `groups:`")
    groups = doc["groups"] or []
    if not isinstance(groups, list):
        raise AuditError(f"{source}: `groups` must be a sequence")
    alerts: list[Alert] = []
    for group_index, group in enumerate(groups):
        where = f"{source}: groups[{group_index}]"
        if not isinstance(group, dict):
            raise AuditError(f"{where} must be a mapping")
        group_labels = _string_map(group.get("labels"), f"{where}.labels")
        rules = group.get("rules") or []
        if not isinstance(rules, list):
            raise AuditError(f"{where}.rules must be a sequence")
        for rule_index, rule in enumerate(rules):
            rule_where = f"{where}.rules[{rule_index}]"
            if not isinstance(rule, dict):
                raise AuditError(f"{rule_where} must be a mapping")
            if "record" in rule:
                continue
            alerts.append(
                Alert(
                    name=_required_string(rule, "alert", rule_where),
                    expr=_required_string(rule, "expr", rule_where),
                    labels={
                        **group_labels,
                        **_string_map(rule.get("labels"), f"{rule_where}.labels"),
                    },
                    annotations=_string_map(rule.get("annotations"), f"{rule_where}.annotations"),
                    source=source,
                )
            )
    return alerts


def rule_files(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    seen: set[Path] = set()
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            found = sorted(
                child
                for child in path.iterdir()
                if child.is_file() and child.suffix in RULE_SUFFIXES
            )
            if not found:
                raise AuditError(f"no *.yml or *.yaml rule files in {raw}")
        elif path.is_file():
            found = [path]
        else:
            raise AuditError(f"no such rule file or directory: {raw}")
        for file in found:
            if file.resolve() not in seen:
                seen.add(file.resolve())
                files.append(file)
    return files


# --- PromQL tokenizer ------------------------------------------------------------------------

_IDENT_RE = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]*")
_NUMBER_RE = re.compile(r"[0-9.][0-9A-Za-z_.]*")  # numbers and durations: 0.95, 5m, 1e3, 0x1f
_LABEL_LIST_KEYWORDS = frozenset({"by", "without", "on", "ignoring", "group_left", "group_right"})
# Words that are never metric names even without a following `(`. Aggregators are here
# because `sum by (x) (...)` puts `by`, not `(`, after them. MetricsQL adds default/if/ifnot.
_KEYWORDS = frozenset(
    {
        "and", "or", "unless", "bool", "offset", "atan2", "inf", "nan",
        "sum", "min", "max", "avg", "group", "stddev", "stdvar", "count", "count_values",
        "bottomk", "topk", "quantile", "limitk", "limit_ratio",
        "default", "if", "ifnot", "keep_metric_names",
    }
)  # fmt: skip
_OUTCOME_MATCHER_RE = re.compile(r"\boutcome\s*(=~|!~|!=|=)\s*([\"'])((?:\\.|(?!\2).)*)\2")


def _skip_string(expr: str, index: int) -> int:
    quote = expr[index]
    index += 1
    while index < len(expr) and expr[index] != quote:
        index += 2 if expr[index] == "\\" and quote != "`" else 1
    return index + 1


def _skip_balanced(expr: str, index: int, opener: str, closer: str) -> int:
    """Index just past the `closer` matching `expr[index] == opener`, skipping strings."""
    depth = 0
    while index < len(expr):
        char = expr[index]
        if char in "\"'`":
            index = _skip_string(expr, index)
            continue
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return len(expr)


def _skip_space(expr: str, index: int) -> int:
    while index < len(expr) and expr[index].isspace():
        index += 1
    return index


def metric_selectors(expr: str) -> list[str]:
    """Series selectors in a PromQL/MetricsQL expr, in order, deduplicated."""
    selectors: list[str] = []
    index = 0
    while index < len(expr):
        char = expr[index]
        if char in "\"'`":
            index = _skip_string(expr, index)
            continue
        if char == "[":
            index = _skip_balanced(expr, index, "[", "]")
            continue
        if char == "{":
            end = _skip_balanced(expr, index, "{", "}")
            selectors.append(expr[index:end])
            index = end
            continue
        number = _NUMBER_RE.match(expr, index) if char.isdigit() or char == "." else None
        if number is not None:
            index = number.end()
            continue
        word = _IDENT_RE.match(expr, index)
        if word is None:
            index += 1
            continue
        after = _skip_space(expr, word.end())
        next_char = expr[after] if after < len(expr) else ""
        lowered = word.group().lower()
        if lowered in _LABEL_LIST_KEYWORDS:
            index = _skip_balanced(expr, after, "(", ")") if next_char == "(" else word.end()
        elif lowered in _KEYWORDS or next_char == "(":
            index = word.end()
        elif next_char == "{":
            index = _skip_balanced(expr, after, "{", "}")
            selectors.append(word.group() + expr[after:index])
        else:
            index = word.end()
            selectors.append(word.group())
    return list(dict.fromkeys(selectors))


def _outcome_values(text: str) -> list[str]:
    values: list[str] = []
    for operator, _quote, value in _OUTCOME_MATCHER_RE.findall(text):
        candidates = value.split("|") if operator in ("=~", "!~") else [value]
        # Only literal alternatives name a vocabulary word; `.+` or `fail.*` do not.
        values.extend(word for word in candidates if re.fullmatch(r"[A-Za-z_]+", word))
    return values


# --- Findings --------------------------------------------------------------------------------


@dataclass(frozen=True)
class Finding:
    severity: str
    alert: str
    reason: str

    def line(self) -> str:
        return f"dead-alert {self.severity} {self.alert} {self.reason}"


def static_findings(alerts: list[Alert], runbook_required: bool) -> list[Finding]:
    findings: list[Finding] = []
    sources: dict[str, list[str]] = {}
    for alert in alerts:
        if runbook_required and not alert.annotations.get("runbook", "").strip():
            findings.append(Finding(MEDIUM, alert.name, f"missing-runbook in {alert.source}"))
        if not alert.labels.get("severity", "").strip():
            findings.append(Finding(MEDIUM, alert.name, f"missing-severity in {alert.source}"))
        used = _outcome_values(alert.expr)
        for key, value in alert.labels.items():
            used.extend([value] if key == "outcome" else _outcome_values(value))
        for value in dict.fromkeys(used):
            if value not in FLEET_OUTCOMES:
                findings.append(
                    Finding(
                        HIGH,
                        alert.name,
                        f'outcome-vocabulary outcome="{value}" in {alert.source}'
                        " (fleet vocabulary is success|failure)",
                    )
                )
        names_sources = sources.setdefault(alert.name, [])
        if alert.source not in names_sources:
            names_sources.append(alert.source)
    for name, files in sources.items():
        if len(files) > 1:
            findings.append(Finding(MEDIUM, name, f"duplicate-name in {', '.join(files)}"))
    return findings


class VictoriaMetrics:
    """Instant queries against a Prometheus-compatible `/api/v1/query`."""

    def __init__(self, base_url: str, timeout: float) -> None:
        self.base_url = base_url
        self._timeout = timeout
        self.queries = 0

    def series_count(self, query: str) -> int:
        url = f"{self.base_url}/api/v1/query?{urllib.parse.urlencode({'query': query})}"
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            raise AuditError(
                f"query {query!r} failed: HTTP {exc.code}{_error_detail(exc.read())}"
            ) from exc
        except OSError as exc:  # URLError, timeouts, refused connections
            reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
            raise AuditError(f"cannot reach {self.base_url}: {reason}") from exc
        self.queries += 1
        try:
            doc = json.loads(body)
        except json.JSONDecodeError as exc:
            raise AuditError(f"query {query!r}: response is not JSON") from exc
        data = doc.get("data") if isinstance(doc, dict) else None
        result = data.get("result") if isinstance(data, dict) else None
        if (
            not isinstance(doc, dict)
            or doc.get("status") != "success"
            or not isinstance(result, list)
        ):
            raise AuditError(f"query {query!r} failed{_error_detail(body)}")
        return len(result)


def _error_detail(body: bytes) -> str:
    try:
        doc = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return ""
    error = doc.get("error") if isinstance(doc, dict) else None
    return f": {error}" if isinstance(error, str) else ""


def _promql_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def live_findings(alerts: list[Alert], client: VictoriaMetrics, since: str) -> list[Finding]:
    findings: list[Finding] = []
    fired: dict[str, bool] = {}
    present: dict[str, bool] = {}
    for alert in alerts:
        if alert.name not in fired:
            selector = f"ALERTS{{alertname={_promql_string(alert.name)}}}"
            fired[alert.name] = client.series_count(f"count_over_time({selector}[{since}])") > 0
            if not fired[alert.name]:
                findings.append(Finding(LOW, alert.name, f"never-fired in {since}"))
        for selector in metric_selectors(alert.expr):
            if selector not in present:
                absent = client.series_count(f"absent_over_time({selector}[{since}])")
                present[selector] = absent == 0
            if not present[selector]:
                findings.append(
                    Finding(
                        HIGH,
                        alert.name,
                        f"references-missing-metric {selector} in {since} ({alert.source})",
                    )
                )
    return findings


# --- CLI -------------------------------------------------------------------------------------


def _validate_since(value: str) -> str:
    if not SINCE_RE.fullmatch(value):
        raise AuditError(f"--since {value!r} is not a duration like 30d or 1w")
    return value


def _validate_vm_url(value: str) -> str:
    parts = urllib.parse.urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise AuditError(f"--vm-url {value!r} must be an http(s) URL like http://nas.box:8428")
    return value.rstrip("/")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="dead_alert_audit.py",
        description="Report vmalert rules that cannot fire or lack routing context.",
    )
    parser.add_argument(
        "--rules", nargs="+", required=True, metavar="PATH", help="rule files or *.yml dirs"
    )
    parser.add_argument("--vm-url", help="VictoriaMetrics base URL; enables the live pass")
    parser.add_argument("--since", default="30d", help="live-pass window (default 30d)")
    parser.add_argument(
        "--runbook-required", action="store_true", help="report alerts with no runbook"
    )
    args = parser.parse_args(argv)

    try:
        since = _validate_since(args.since)
        vm_url = _validate_vm_url(args.vm_url) if args.vm_url else None
        files = rule_files(args.rules)
        alerts = [alert for file in files for alert in load_alerts(file)]
        log(f"parsed {len(alerts)} alerts from {len(files)} rule files")
        findings = static_findings(alerts, args.runbook_required)
        log(f"static pass: {len(findings)} findings")
        if vm_url is None:
            log("live pass skipped (no --vm-url)")
        else:
            client = VictoriaMetrics(vm_url, QUERY_TIMEOUT_SECONDS)
            started = time.monotonic()
            live = live_findings(alerts, client, since)
            log(
                f"live pass against {vm_url} over {since}: {len(live)} findings,"
                f" {client.queries} queries in {time.monotonic() - started:.1f}s"
            )
            findings.extend(live)
    except AuditError as exc:
        log(str(exc))
        return EXIT_USAGE

    for finding in findings:
        print(finding.line())
    print(f"dead_alert_audit: {len(findings)} findings over {len(alerts)} alerts")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
