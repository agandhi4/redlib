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
        self.base = self.dir / "main-ratchet.json"

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

    def check(self, *extra: str, base: object = "same") -> subprocess.CompletedProcess[str]:
        """Run `check`. base="same" copies the PR bounds as main's (no bound moved); a dict is
        written as main's bounds; None passes no base option (the git ref default applies)."""
        args = ["check", "--snapshot", str(self.snapshot), "--bounds", str(self.bounds)]
        if base == "same":
            self.base.write_text(self.bounds.read_text(encoding="utf-8"), encoding="utf-8")
            args += ["--base-bounds", str(self.base)]
        elif base is not None:
            self.write(self.base, base)
            args += ["--base-bounds", str(self.base)]
        return self.run_ratchet(*args, *extra)

    def tighten(self) -> subprocess.CompletedProcess[str]:
        return self.run_ratchet(
            "tighten", "--snapshot", str(self.snapshot), "--bounds", str(self.bounds)
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
        self.assertIn("ratchet cycles 0 vs 0 SAME", result.stdout)
        self.assertIn("ratchet coverage 80 vs 80 SAME", result.stdout)

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

    def test_better_passes_with_a_tighten_hint_and_leaves_bounds(self) -> None:
        self.write(self.snapshot, {"dup": 3})
        self.write(self.bounds, {"dup": {"direction": "lower", "bound": 5}})
        before = self.bounds.read_text(encoding="utf-8")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet dup 3 vs 5 BETTER", result.stdout)
        self.assertIn("make metrics-tighten", result.stdout)
        self.assertEqual(self.bounds.read_text(encoding="utf-8"), before)

    def test_check_has_no_tighten_flag(self) -> None:
        # Decision A: the PR tightens through the subcommand; check never writes.
        self.write(self.snapshot, {"dup": 3})
        self.write(self.bounds, {"dup": {"direction": "lower", "bound": 5}})
        self.assertEqual(self.check("--tighten").returncode, 2)

    def test_tighten_moves_only_improved_bounds_in_both_directions(self) -> None:
        self.write(self.snapshot, {"dup": 3, "coverage": 85, "cycles": 1, "loc": 9})
        self.write(
            self.bounds,
            {
                "dup": {"direction": "lower", "bound": 5},
                "coverage": {"direction": "higher", "bound": 80},
                "cycles": {"direction": "lower", "bound": 0},
                "gone": {"direction": "lower", "bound": 4},
            },
        )
        result = self.tighten()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet dup 5 -> 3", result.stdout)
        self.assertIn("ratchet gone - vs 4 MISSING (left as is)", result.stdout)
        self.assertIn("ratchet tightened 2 bound(s)", result.stdout)
        self.assertEqual(
            self.bounds_doc(),
            {
                "dup": {"direction": "lower", "bound": 3},
                "coverage": {"direction": "higher", "bound": 85},
                "cycles": {"direction": "lower", "bound": 0},  # worse stays: never loosened
                "gone": {"direction": "lower", "bound": 4},
            },
        )

    def test_tighten_with_nothing_better_does_not_rewrite(self) -> None:
        self.write(self.snapshot, {"cycles": 0})
        self.bounds.write_text('{"cycles": {"bound": 0, "direction": "lower"}}', encoding="utf-8")
        before = self.bounds.read_text(encoding="utf-8")
        result = self.tighten()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet tightened 0 bound(s)", result.stdout)
        self.assertEqual(self.bounds.read_text(encoding="utf-8"), before)

    def test_tightened_bounds_pass_check_against_main(self) -> None:
        main = {"dup": {"direction": "lower", "bound": 5}}
        self.write(self.snapshot, {"dup": 3})
        self.write(self.bounds, main)
        self.tighten()
        result = self.check(base=main)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ratchet-bound dup lower:5 -> lower:3 TIGHTENED", result.stdout)
        self.assertIn("ratchet dup 3 vs 3 SAME", result.stdout)

    def test_bound_looser_than_main_fails_without_label(self) -> None:
        # The contradiction-4 bug: the PR edits its own bounds file to let a regression in.
        self.write(self.snapshot, {"cycles": 2, "coverage": 70})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "lower", "bound": 2},
                "coverage": {"direction": "higher", "bound": 70},
            },
        )
        main = {
            "cycles": {"direction": "lower", "bound": 0},
            "coverage": {"direction": "higher", "bound": 80},
        }
        result = self.check(base=main)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ratchet-bound cycles lower:0 -> lower:2 LOOSENED", result.stdout)
        self.assertIn("ratchet-bound coverage higher:80 -> higher:70 LOOSENED", result.stdout)
        self.assertIn("loosened=2", result.stdout)
        self.assertIn("2 bound(s) looser than main", result.stderr)
        accepted = self.check("--rebaseline-ok", base=main)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn("ratchet rebaseline accepted", accepted.stdout)

    def test_removed_metric_and_flipped_direction_count_as_loosening(self) -> None:
        self.write(self.snapshot, {"cycles": 0, "new": 1})
        self.write(
            self.bounds,
            {
                "cycles": {"direction": "higher", "bound": 0},
                "new": {"direction": "lower", "bound": 1},
            },
        )
        main = {
            "cycles": {"direction": "lower", "bound": 0},
            "gone": {"direction": "lower", "bound": 4},
        }
        result = self.check(base=main)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ratchet-bound cycles lower:0 -> higher:0 DIRECTION", result.stdout)
        self.assertIn("ratchet-bound gone lower:4 -> - REMOVED", result.stdout)
        self.assertIn("ratchet-bound new - -> lower:1 ADDED", result.stdout)
        self.assertIn("loosened=2", result.stdout)
        self.assertEqual(self.check("--rebaseline-ok", base=main).returncode, 0)

    def test_unset_bound_is_refused_by_check_and_filled_by_rebaseline(self) -> None:
        self.write(self.snapshot, {"coverage.backend.lines": 81.5})
        self.write(self.bounds, {"coverage.backend.lines": {"direction": "higher", "bound": None}})
        result = self.check()
        self.assertEqual(result.returncode, 2)
        self.assertIn("unset; run `metrics_ratchet.py rebaseline`", result.stderr)
        rebased = self.run_ratchet(
            "rebaseline", "--snapshot", str(self.snapshot), "--bounds", str(self.bounds)
        )
        self.assertEqual(rebased.returncode, 0, rebased.stderr)
        self.assertEqual(
            self.bounds_doc(), {"coverage.backend.lines": {"direction": "higher", "bound": 81.5}}
        )

    def test_starter_template_is_valid_and_all_unset(self) -> None:
        template = SCRIPT.parent.parent / "templates" / "metrics" / "ratchet.json"
        doc = json.loads(template.read_text(encoding="utf-8"))
        self.assertTrue(doc)
        for key, entry in doc.items():
            self.assertNotRegex(key, r"\s")
            self.assertIn(entry["direction"], ("lower", "higher"), key)
            self.assertIsNone(entry["bound"], key)

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

    def test_whitespace_in_a_bound_key_is_invalid(self) -> None:
        self.write(self.snapshot, {"cycles": 0})
        self.write(self.bounds, {"statements.GET /x": {"direction": "lower", "bound": 0}})
        result = self.check(base=None)
        self.assertEqual(result.returncode, 2)
        self.assertIn("contains whitespace", result.stderr)

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


class MergeTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def merge(self, *inputs: object) -> tuple[subprocess.CompletedProcess[str], Path]:
        paths = []
        for i, doc in enumerate(inputs):
            path = self.dir / "build" / "metrics" / f"c{i}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(doc), encoding="utf-8")
            paths.append(str(path))
        out = self.dir / "build" / "metrics.json"
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "merge", "--out", str(out), *paths],
            capture_output=True,
            text=True,
            check=False,
        )
        return result, out

    def test_merges_flat_nested_and_envelope_inputs_into_one_flat_map(self) -> None:
        result, out = self.merge(
            {"coverage.backend.lines": 81.5},
            {"statements": {"GET:/api/items": 3}, "note": "ignored", "top": [1, 2]},
            {"commit": {"sha": "abc"}, "metrics": {"backend": {"complexity": {"max": 29}}},
             "schema_version": 1},
        )  # fmt: skip
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("merged 3 metric(s) from 3 file(s)", result.stdout)
        self.assertEqual(
            json.loads(out.read_text(encoding="utf-8")),
            {
                "backend.complexity.max": 29,
                "coverage.backend.lines": 81.5,
                "statements.GET:/api/items": 3,
            },
        )

    def test_a_key_from_two_collectors_is_an_error(self) -> None:
        result, out = self.merge({"dup.jscpd.percent": 1}, {"dup": {"jscpd": {"percent": 2}}})
        self.assertEqual(result.returncode, 2)
        self.assertIn("emitted by both", result.stderr)
        self.assertFalse(out.exists())

    def test_whitespace_key_and_unreadable_input_are_errors(self) -> None:
        result, _ = self.merge({"statements": {"GET /api/items": 3}})
        self.assertEqual(result.returncode, 2)
        self.assertIn("contains whitespace", result.stderr)
        missing = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "merge", "--out", str(self.dir / "o.json"),
             str(self.dir / "build" / "metrics" / "*.json")],
            capture_output=True,
            text=True,
            check=False,
        )  # fmt: skip
        self.assertEqual(missing.returncode, 2)  # an unmatched glob arrives literally


class BaseRefTest(unittest.TestCase):
    """`check` with no base option reads main's bounds through git, the way the gate runs it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name) / "repo"
        self.bounds = self.repo / "docs" / "metrics" / "ratchet.json"
        self.snapshot = self.repo / "build" / "metrics.json"
        self.bounds.parent.mkdir(parents=True)
        self.snapshot.parent.mkdir(parents=True)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        (self.repo / "README").write_text("x\n", encoding="utf-8")
        self.git("add", "README")
        self.git("commit", "-qm", "init")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def publish_main(self) -> None:
        # Stand-in for origin/main: the gate fetches it; here a local ref is enough.
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def check(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "check", "--snapshot", str(self.snapshot),
             "--bounds", str(self.bounds), *extra],
            capture_output=True,
            text=True,
            check=False,
        )  # fmt: skip

    def test_first_adoption_has_no_base(self) -> None:
        self.publish_main()
        self.snapshot.write_text('{"cycles": 0}', encoding="utf-8")
        self.bounds.write_text('{"cycles": {"direction": "lower", "bound": 0}}', encoding="utf-8")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "ratchet base none (docs/metrics/ratchet.json is not on origin/main: first adoption)",
            result.stdout,
        )

    def test_loosening_against_the_committed_main_copy_fails(self) -> None:
        self.bounds.write_text('{"cycles": {"direction": "lower", "bound": 0}}', encoding="utf-8")
        self.git("add", "docs")
        self.git("commit", "-qm", "bounds")
        self.publish_main()
        self.snapshot.write_text('{"cycles": 3}', encoding="utf-8")
        self.bounds.write_text('{"cycles": {"direction": "lower", "bound": 3}}', encoding="utf-8")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("ratchet base origin/main:docs/metrics/ratchet.json", result.stdout)
        self.assertIn("ratchet-bound cycles lower:0 -> lower:3 LOOSENED", result.stdout)

    def test_unresolvable_base_ref_fails_closed(self) -> None:
        self.snapshot.write_text('{"cycles": 0}', encoding="utf-8")
        self.bounds.write_text('{"cycles": {"direction": "lower", "bound": 0}}', encoding="utf-8")
        result = self.check()  # no origin/main at all
        self.assertEqual(result.returncode, 2)
        self.assertIn("base ref origin/main does not resolve", result.stderr)
        self.assertEqual(self.check("--base-ref", "nope").returncode, 2)


if __name__ == "__main__":
    unittest.main()
