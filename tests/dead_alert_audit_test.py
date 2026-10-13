"""Contract tests for bin/dead_alert_audit.py.

The CLI runs as a subprocess the way the monthly review runs it; the YAML subset parser and
the PromQL tokenizer are also tested directly, since every finding depends on them.

Run: python3 -I tests/dead_alert_audit_test.py
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import ModuleType

SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "dead_alert_audit.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("dead_alert_audit", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # bin/ is vendored into consumers; a __pycache__ there would trip devkit-check.
    sys.dont_write_bytecode = True
    # dataclasses resolve string annotations through sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


audit = _load_module()

CLEAN_RULE = """\
groups:
  - name: app
    rules:
      - alert: {name}
        expr: {expr}
        labels:
          severity: page
        annotations:
          runbook: check docs/troubleshooting.md#jobs
"""


class AuditCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, name: str, text: str) -> Path:
        path = self.dir / name
        path.write_text(textwrap.dedent(text), encoding="utf-8")
        return path

    def run_audit(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def findings(self, result: subprocess.CompletedProcess[str]) -> list[str]:
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line for line in result.stdout.splitlines() if line.startswith("dead-alert ")]


class StaticPassTest(AuditCase):
    def test_clean_rule_has_no_findings(self) -> None:
        rules = self.write("a.yml", CLEAN_RULE.format(name="JobFailed", expr="up == 0"))
        result = self.run_audit("--rules", str(rules), "--runbook-required")
        self.assertEqual(self.findings(result), [])
        self.assertIn("dead_alert_audit: 0 findings over 1 alerts", result.stdout)
        self.assertIn("live pass skipped", result.stderr)

    def test_missing_runbook_only_when_required(self) -> None:
        rules = self.write(
            "a.yml",
            """\
            groups:
              - name: app
                rules:
                  - alert: NoRunbook
                    expr: up == 0
                    labels:
                      severity: page
            """,
        )
        self.assertEqual(self.findings(self.run_audit("--rules", str(rules))), [])
        found = self.findings(self.run_audit("--rules", str(rules), "--runbook-required"))
        self.assertEqual(found, [f"dead-alert medium NoRunbook missing-runbook in {rules}"])

    def test_missing_severity_unless_group_labels_supply_it(self) -> None:
        rules = self.write(
            "a.yml",
            """\
            groups:
              - name: bare
                rules:
                  - alert: NoSeverity
                    expr: up == 0
              - name: labelled
                labels:
                  severity: page
                rules:
                  - alert: GroupSeverity
                    expr: up == 0
            """,
        )
        found = self.findings(self.run_audit("--rules", str(rules)))
        self.assertEqual(found, [f"dead-alert medium NoSeverity missing-severity in {rules}"])

    def test_outcome_vocabulary_misuse_in_expr_and_labels(self) -> None:
        rules = self.write(
            "a.yml",
            """\
            groups:
              - name: app
                labels:
                  severity: page
                rules:
                  - alert: ErrorOutcome
                    expr: increase(job_duration_seconds_count{outcome="error"}[15m]) > 0
                  - alert: RegexOutcome
                    expr: increase(jobs_total{outcome=~"failure|failed|.+"}[15m]) > 0
                  - alert: LabelOutcome
                    expr: up == 0
                    labels:
                      outcome: ok
                  - alert: FleetOutcome
                    expr: increase(job_duration_seconds_count{outcome="failure"}[15m]) > 0
            """,
        )
        found = self.findings(self.run_audit("--rules", str(rules)))
        suffix = f"in {rules} (fleet vocabulary is success|failure)"
        self.assertEqual(
            found,
            [
                f'dead-alert high ErrorOutcome outcome-vocabulary outcome="error" {suffix}',
                f'dead-alert high RegexOutcome outcome-vocabulary outcome="failed" {suffix}',
                f'dead-alert high LabelOutcome outcome-vocabulary outcome="ok" {suffix}',
            ],
        )

    def test_duplicate_name_across_files_not_within_one(self) -> None:
        rules = self.dir / "rules"
        rules.mkdir()
        first = self.write(
            "rules/a.yml",
            """\
            groups:
              - name: a
                labels:
                  severity: page
                rules:
                  - alert: Twice
                    expr: up == 0
                  - alert: SameFile
                    expr: up == 0
                  - alert: SameFile
                    expr: up == 1
            """,
        )
        second = self.write("rules/b.yaml", CLEAN_RULE.format(name="Twice", expr="up == 0"))
        self.write("rules/notes.txt", "not a rule file")
        result = self.run_audit("--rules", str(rules))
        self.assertEqual(
            self.findings(result), [f"dead-alert medium Twice duplicate-name in {first}, {second}"]
        )
        self.assertIn("1 findings over 4 alerts", result.stdout)

    def test_recording_rules_are_skipped(self) -> None:
        rules = self.write(
            "a.yml",
            """\
            groups:
              - name: rec
                rules:
                  - record: app:requests:rate5m
                    expr: sum(rate(http_request_duration_seconds_count[5m]))
            """,
        )
        result = self.run_audit("--rules", str(rules), "--runbook-required")
        self.assertIn("0 findings over 0 alerts", result.stdout)


class UsageErrorTest(AuditCase):
    def assert_usage_error(self, result: subprocess.CompletedProcess[str], text: str) -> None:
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn(text, result.stderr)

    def test_missing_path(self) -> None:
        result = self.run_audit("--rules", str(self.dir / "nope.yml"))
        self.assert_usage_error(result, "no such rule file")

    def test_empty_directory(self) -> None:
        self.assert_usage_error(self.run_audit("--rules", str(self.dir)), "no *.yml")

    def test_no_arguments(self) -> None:
        self.assertEqual(self.run_audit().returncode, 2)

    def test_bad_since(self) -> None:
        rules = self.write("a.yml", CLEAN_RULE.format(name="A", expr="up == 0"))
        self.assert_usage_error(
            self.run_audit("--rules", str(rules), "--since", "30 days"), "--since"
        )

    def test_vm_url_must_be_http(self) -> None:
        rules = self.write("a.yml", CLEAN_RULE.format(name="A", expr="up == 0"))
        result = self.run_audit("--rules", str(rules), "--vm-url", "file:///etc/passwd")
        self.assert_usage_error(result, "must be an http(s) URL")

    def test_unsupported_yaml_names_file_and_line(self) -> None:
        rules = self.write(
            "a.yml",
            """\
            groups:
              - name: app
                rules: [{alert: A, expr: up}]
            """,
        )
        self.assert_usage_error(
            self.run_audit("--rules", str(rules)), f"{rules}:3: flow collections"
        )

    def test_rule_without_expr(self) -> None:
        rules = self.write(
            "a.yml",
            """\
            groups:
              - name: app
                rules:
                  - alert: NoExpr
            """,
        )
        self.assert_usage_error(self.run_audit("--rules", str(rules)), "needs a non-empty `expr`")

    def test_not_a_rule_file(self) -> None:
        rules = self.write("a.yml", "scrape_configs:\n  - job_name: x\n")
        self.assert_usage_error(self.run_audit("--rules", str(rules)), "with `groups:`")


class YamlSubsetTest(unittest.TestCase):
    def parse(self, text: str) -> object:
        return audit.parse_yaml(textwrap.dedent(text), "test.yml")

    def test_rule_file_shapes(self) -> None:
        doc = self.parse(
            """\
            ---
            # header comment
            groups:
            - name: g   # compact sequence under its key
              rules:
              - alert: Literal
                expr: |
                  sum(rate(a[5m]))
                    / sum(rate(b[5m])) > 0.05
                annotations:
                  single: 'it''s {{ $labels.app }}'
                  double: "line\\tone # not a comment"
                  plain: a value # a comment
              - alert: Folded
                expr: >-
                  up
                  == 0
              - alert: Wrapped
                expr: sum(x)
                  > 1
                labels: {}
            """
        )
        literal = {
            "alert": "Literal",
            "expr": "sum(rate(a[5m]))\n  / sum(rate(b[5m])) > 0.05\n",
            "annotations": {
                "single": "it's {{ $labels.app }}",
                "double": "line\tone # not a comment",
                "plain": "a value",
            },
        }
        folded = {"alert": "Folded", "expr": "up == 0"}
        wrapped = {"alert": "Wrapped", "expr": "sum(x) > 1", "labels": {}}
        self.assertEqual(doc, {"groups": [{"name": "g", "rules": [literal, folded, wrapped]}]})

    def test_rejections(self) -> None:
        cases = {
            "a: &anchor x\n": "anchor",
            "a:\n\t- b\n": "tab",
            "a: x\n---\nb: y\n": "multiple documents",
            "a: x\na: y\n": "duplicate key",
            "a: 'open\n": "unterminated",
            "a: b: c\n": "quote it",
            "a:\n  b:\n    - x\n   c: y\n": "unexpected indentation",
        }
        for text, message in cases.items():
            with self.subTest(text=text):
                with self.assertRaisesRegex(audit.AuditError, message):
                    audit.parse_yaml(text, "t.yml")


class MetricSelectorTest(unittest.TestCase):
    def test_selectors(self) -> None:
        cases = {
            "histogram_quantile(0.95, sum by (app, le) "
            "(rate(http_request_duration_seconds_bucket[5m]))) > 1": [
                "http_request_duration_seconds_bucket"
            ],
            'up{expect_up="true"} == 0 or scrape_samples_scraped{expect_up="true"} == 0': [
                'up{expect_up="true"}',
                'scrape_samples_scraped{expect_up="true"}',
            ],
            "sum by (app) (pg_stat_activity_count) / on (app) group_left(x) "
            "max by (app) (pg_settings_max_connections) > 0.8": [
                "pg_stat_activity_count",
                "pg_settings_max_connections",
            ],
            'rate(x{a="}{ by"}[5m] offset 1h) and bool y unless z': [
                'x{a="}{ by"}',
                "y",
                "z",
            ],
            'sum(rate(foo[5m:1m])) by (le) + foo + {__name__="bar"}': [
                "foo",
                '{__name__="bar"}',
            ],
            "time() - job_last_success_timestamp_seconds > 2 * 3600": [
                "job_last_success_timestamp_seconds"
            ],
            "vector(1)": [],
        }
        for expr, expected in cases.items():
            with self.subTest(expr=expr):
                self.assertEqual(audit.metric_selectors(expr), expected)


class FakeVictoriaMetrics:
    """Answers /api/v1/query from a map of PromQL query -> series count; records queries."""

    def __init__(self, series: dict[str, int], status: str = "success") -> None:
        self.series = series
        self.status = status
        self.queries: list[str] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - http.server's naming
                parsed = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parsed.query).get("query", [""])[0]
                fake.queries.append(query)
                if parsed.path != "/api/v1/query" or fake.status != "success":
                    body = {"status": "error", "error": "unparseable"}
                    code = 422
                else:
                    result = [{"metric": {}, "value": [0, "1"]}] * fake.series.get(query, 0)
                    body = {"status": "success", "data": {"resultType": "vector", "result": result}}
                    code = 200
                payload = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, format: str, *args: object) -> None:
                del format, args

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> FakeVictoriaMetrics:
        self.thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()


class LivePassTest(AuditCase):
    def rules(self) -> Path:
        return self.write(
            "a.yml",
            """\
            groups:
              - name: app
                labels:
                  severity: page
                rules:
                  - alert: Fired
                    expr: present_metric > 1
                  - alert: Quiet
                    expr: present_metric > 100 or gone_metric{name="x"} > 0
            """,
        )

    def test_never_fired_and_missing_metric(self) -> None:
        series = {
            'count_over_time(ALERTS{alertname="Fired"}[7d])': 3,
            'absent_over_time(gone_metric{name="x"}[7d])': 1,
        }
        rules = self.rules()
        with FakeVictoriaMetrics(series) as vm:
            result = self.run_audit(
                "--rules", str(rules), "--vm-url", vm.url + "/", "--since", "7d"
            )
        self.assertEqual(
            self.findings(result),
            [
                "dead-alert low Quiet never-fired in 7d",
                "dead-alert high Quiet references-missing-metric"
                f' gone_metric{{name="x"}} in 7d ({rules})',
            ],
        )
        # One query per distinct alert name and selector: present_metric is asked once.
        self.assertEqual(vm.queries.count("absent_over_time(present_metric[7d])"), 1)
        self.assertEqual(len(vm.queries), 4)
        self.assertIn("live pass against", result.stderr)

    def test_query_error_is_exit_2(self) -> None:
        with FakeVictoriaMetrics({}, status="error") as vm:
            result = self.run_audit("--rules", str(self.rules()), "--vm-url", vm.url)
        self.assertEqual(result.returncode, 2)
        self.assertIn("HTTP 422: unparseable", result.stderr)
        self.assertNotIn("findings over", result.stdout)

    def test_unreachable_is_exit_2(self) -> None:
        with FakeVictoriaMetrics({}) as vm:
            url = vm.url
        result = self.run_audit("--rules", str(self.rules()), "--vm-url", url)
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"cannot reach {url}", result.stderr)


if __name__ == "__main__":
    unittest.main()
