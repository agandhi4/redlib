"""Contract tests for bin/metrics_ratchet.py, run as a subprocess the way the gate runs it.

Run: python3 -m unittest tests.metrics_ratchet_test   (or python3 tests/metrics_ratchet_test.py)
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "metrics_ratchet.py"


class RatchetTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.snapshot = self.dir / "snapshot.json"
        self.bounds = self.dir / "ratchet.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, path: Path, doc: object) -> None:
        path.write_text(json.dumps(doc), encoding="utf-8")

    def run_ratchet(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def check(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.run_ratchet(
            "check", "--snapshot", str(self.snapshot), "--bounds", str(self.bounds), *extra
        )

    def bounds_doc(self) -> object:
        return json.loads(self.bounds.read_text(encoding="utf-8"))

    def test_within_bounds_passes(self) -> None:
        self.write(self.snapshot, {"cycles": 0, "coverage": 80})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "lower", "bound": 0},
                "coverage": {"direction": "higher", "bound": 80},
            },
        )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet cycles 0 vs 0 OK", result.stdout)
        self.assertIn("ratchet coverage 80 vs 80 OK", result.stdout)

    def test_worse_fails_in_both_directions(self) -> None:
        self.write(self.snapshot, {"cycles": 2, "coverage": 79.5})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "lower", "bound": 1},
                "coverage": {"direction": "higher", "bound": 80},
            },
        )
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ratchet cycles 2 vs 1 WORSE", result.stdout)
        self.assertIn("ratchet coverage 79.5 vs 80 WORSE", result.stdout)
        self.assertIn("metrics-rebaseline", result.stderr)

    def test_worse_with_rebaseline_ok_passes_without_writing(self) -> None:
        self.write(self.snapshot, {"cycles": 2})
        self.write(self.bounds, {"cycles": {"direction": "lower", "bound": 1}})
        before = self.bounds.read_text(encoding="utf-8")
        result = self.check("--rebaseline-ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet rebaseline accepted", result.stdout)
        self.assertEqual(self.bounds.read_text(encoding="utf-8"), before)

    def test_better_with_tighten_rewrites_only_improved_bounds(self) -> None:
        self.write(self.snapshot, {"dup": 3, "coverage": 85, "cycles": 0})
        self.write(
            self.bounds,
            {
                "dup": {"direction": "lower", "bound": 5},
                "coverage": {"direction": "higher", "bound": 80},
                "cycles": {"direction": "lower", "bound": 0},
            },
        )
        result = self.check("--tighten")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet dup 3 vs 5 BETTER", result.stdout)
        self.assertEqual(
            self.bounds_doc(),
            {
                "dup": {"direction": "lower", "bound": 3},
                "coverage": {"direction": "higher", "bound": 85},
                "cycles": {"direction": "lower", "bound": 0},
            },
        )

    def test_better_without_tighten_leaves_bounds(self) -> None:
        self.write(self.snapshot, {"dup": 3})
        self.write(self.bounds, {"dup": {"direction": "lower", "bound": 5}})
        before = self.bounds.read_text(encoding="utf-8")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bounds.read_text(encoding="utf-8"), before)

    def test_tighten_does_not_write_when_another_metric_is_worse(self) -> None:
        self.write(self.snapshot, {"dup": 3, "cycles": 1})
        self.write(
            self.bounds,
            {
                "dup": {"direction": "lower", "bound": 5},
                "cycles": {"direction": "lower", "bound": 0},
            },
        )
        before = self.bounds.read_text(encoding="utf-8")
        result = self.check("--tighten")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.bounds.read_text(encoding="utf-8"), before)

    def test_untracked_is_info_not_failure(self) -> None:
        self.write(self.snapshot, {"cycles": 0, "loc": 1234})
        self.write(self.bounds, {"cycles": {"direction": "lower", "bound": 0}})
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("untracked=1", result.stdout)
        self.assertNotIn("ratchet loc", result.stdout)
        listed = self.check("--show-untracked")
        self.assertIn("ratchet loc 1234 UNTRACKED", listed.stdout)

    def test_missing_tracked_metric_fails_even_with_rebaseline_ok(self) -> None:
        self.write(self.snapshot, {"cycles": 0})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "lower", "bound": 0},
                "gone": {"direction": "lower", "bound": 4},
            },
        )
        for extra in ((), ("--rebaseline-ok",)):
            result = self.check(*extra)
            self.assertEqual(result.returncode, 1, extra)
            self.assertIn("ratchet gone - vs 4 MISSING", result.stdout)

    def test_malformed_json_exits_2(self) -> None:
        self.snapshot.write_text("{not json", encoding="utf-8")
        self.write(self.bounds, {"cycles": {"direction": "lower", "bound": 0}})
        self.assertEqual(self.check().returncode, 2)
        self.write(self.snapshot, {"cycles": 0})
        self.bounds.write_text("[1,", encoding="utf-8")
        self.assertEqual(self.check().returncode, 2)

    def test_missing_file_and_usage_errors_exit_2(self) -> None:
        self.write(self.bounds, {"cycles": {"direction": "lower", "bound": 0}})
        self.assertEqual(self.check().returncode, 2)  # snapshot never written
        self.assertEqual(self.run_ratchet("check").returncode, 2)
        self.assertEqual(self.run_ratchet("frobnicate").returncode, 2)

    def test_bounds_validation(self) -> None:
        self.write(self.snapshot, {"cycles": 0})
        invalid = [
            {"cycles": {"direction": "down", "bound": 0}},
            {"cycles": {"direction": "lower"}},
            {"cycles": {"direction": "lower", "bound": "0"}},
            {"cycles": {"direction": "lower", "bound": True}},
            {"cycles": {"direction": "lower", "bound": 0, "extra": 1}},
            {"cycles": 0},
            ["cycles"],
        ]
        for doc in invalid:
            self.write(self.bounds, doc)
            result = self.check()
            self.assertEqual(result.returncode, 2, doc)
            self.assertIn("ratchet ERROR", result.stderr)

    def test_rebaseline_writes_exactly_the_tracked_keys(self) -> None:
        self.write(self.snapshot, {"cycles": 3, "coverage": 70, "loc": 999})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "lower", "bound": 0},
                "coverage": {"direction": "higher", "bound": 80},
            },
        )
        result = self.run_ratchet(
            "rebaseline", "--snapshot", str(self.snapshot), "--bounds", str(self.bounds)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.bounds_doc(),
            {
                "cycles": {"direction": "lower", "bound": 3},
                "coverage": {"direction": "higher", "bound": 70},
            },
        )

    def test_rebaseline_refuses_when_tracked_metric_missing(self) -> None:
        self.write(self.snapshot, {"cycles": 3})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "lower", "bound": 0},
                "gone": {"direction": "lower", "bound": 1},
            },
        )
        before = self.bounds.read_text(encoding="utf-8")
        result = self.run_ratchet(
            "rebaseline", "--snapshot", str(self.snapshot), "--bounds", str(self.bounds)
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.bounds.read_text(encoding="utf-8"), before)

    def test_finplat_snapshot_envelope_is_flattened(self) -> None:
        self.write(
            self.snapshot,
            {
                "commit": {"dirty": False, "sha": "f541674fd21c"},
                "metrics": {
                    "backend": {"complexity": {"max": 29, "top": [{"name": "x", "value": 29}]}},
                    "coupling": {"frontend": {"cycles": 0}},
                },
                "schema_version": 1,
            },
        )
        self.write(
            self.bounds,
            {
                "backend.complexity.max": {"direction": "lower", "bound": 30},
                "coupling.frontend.cycles": {"direction": "lower", "bound": 0},
            },
        )
        result = self.check("--show-untracked")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet backend.complexity.max 29 vs 30 BETTER", result.stdout)
        self.assertIn("untracked=0", result.stdout)  # commit.*, schema_version, lists excluded


if __name__ == "__main__":
    unittest.main()
