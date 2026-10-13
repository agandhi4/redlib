"""Contract tests for bin/own_commit_check.py, run as a subprocess the way a repo's gate runs it.

Run: python3 -I tests/own_commit_check_test.py  (or python3 -m unittest tests.own_commit_check_test)
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "bin" / "own_commit_check.py"


class OwnCommitCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.root = self.dir / "src"
        self.root.mkdir()
        self.allowlist = self.dir / "own_commit_allowlist.txt"
        self.allowlist.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def source(self, rel: str, code: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(code), encoding="utf-8")

    def allow(self, *lines: str) -> None:
        self.allowlist.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def check(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-I",
                str(SCRIPT),
                "--root",
                str(self.root),
                "--allowlist",
                str(self.allowlist),
                *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_passes(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_fails_with(self, result: subprocess.CompletedProcess[str], text: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(text, result.stdout)

    # Opener-owned commits

    def test_own_session_commit_passes(self) -> None:
        self.source(
            "svc.py",
            """
            def record(engine):
                with Session(engine) as db:
                    db.add(1)
                    db.commit()

            def assigned():
                s = SessionLocal()
                s.commit()
            """,
        )
        result = self.check()
        self.assert_passes(result)
        self.assertIn("own_commit_allowlist_entries=0", result.stdout)

    def test_async_own_session_commit_passes(self) -> None:
        self.source(
            "svc.py",
            """
            async def record():
                async with AsyncSession() as db:
                    await db.commit()
            """,
        )
        self.assert_passes(self.check())

    def test_custom_opener_regex(self) -> None:
        self.source(
            "svc.py",
            """
            async def record():
                async with session_context(read_only=False) as db:
                    await db.commit()
            """,
        )
        self.assert_fails_with(self.check(), "raw commit on borrowed session db")
        self.assert_passes(self.check("--session-opener-regex", r"session_context\("))

    def test_session_opened_by_outer_function_is_borrowed_in_closure(self) -> None:
        self.source(
            "svc.py",
            """
            def outer():
                with Session() as db:
                    def inner():
                        db.commit()
                    inner()
            """,
        )
        self.assert_fails_with(self.check(), "svc.py:5: raw commit on borrowed session db")

    # Borrowed-session commits

    def test_borrowed_raw_commit_flagged(self) -> None:
        self.source(
            "svc.py",
            """
            def record(db):
                db.add(1)
                db.commit()
            """,
        )
        self.assert_fails_with(
            self.check(), "svc.py:4: raw commit on borrowed session db; use commit_now(reason=...)"
        )

    def test_async_borrowed_raw_commit_flagged(self) -> None:
        self.source(
            "svc.py",
            """
            class Repo:
                async def save(self):
                    await self.session.commit()

            async def touch():
                await get_session().commit()
            """,
        )
        result = self.check()
        self.assert_fails_with(result, "svc.py:4: raw commit on borrowed session self.session")
        self.assertIn("svc.py:7: raw commit on borrowed session get_session()", result.stdout)

    def test_helper_body_is_exempt(self) -> None:
        self.source(
            "core/database.py",
            """
            async def commit_now(session, *, reason):
                await session.commit()
            """,
        )
        self.assert_passes(self.check())

    # Helper calls and the allow-list

    def test_unlisted_helper_call_flagged(self) -> None:
        self.source(
            "svc.py",
            """
            async def stamp(db):
                await commit_now(db, reason=Reason.AUTH_BOOKKEEPING)
            """,
        )
        self.assert_fails_with(
            self.check(), "svc.py:3: add svc.py::stamp to the allow-list with a reviewed reason"
        )

    def test_listed_helper_call_passes(self) -> None:
        self.source(
            "pkg/svc.py",
            """
            class Auth:
                async def stamp(self, db):
                    await commit_now(db, reason=Reason.AUTH_BOOKKEEPING)

            def claim():
                transaction.commit_now(reason=Reason.LEASE)
            """,
        )
        self.allow(
            "# reviewed exceptions",
            "pkg/svc.py::Auth.stamp  AUTH_BOOKKEEPING  # last_used_at survives the request",
            "pkg/svc.py::claim 1 LEASE",
        )
        result = self.check()
        self.assert_passes(result)
        self.assertIn("own_commit_allowlist_entries=2", result.stdout)

    def test_helper_call_without_reason_flagged(self) -> None:
        self.source(
            "svc.py",
            """
            async def stamp(db):
                await commit_now(db)
            """,
        )
        self.allow("svc.py::stamp")
        self.assert_fails_with(self.check(), "svc.py:3: commit_now call without reason=")

    def test_listed_but_raw_commit_says_remove(self) -> None:
        self.source(
            "svc.py",
            """
            async def stamp(db):
                await db.commit()
            """,
        )
        self.allow("svc.py::stamp SURVIVES_RAISE")
        result = self.check()
        self.assert_fails_with(result, "raw commit on borrowed session db")
        self.assertIn("remove svc.py::stamp from the allow-list", result.stdout)

    def test_listed_but_missing_function_says_remove(self) -> None:
        self.source("svc.py", "def other():\n    pass\n")
        self.allow("svc.py::gone LEASE", "missing.py::f LEASE")
        result = self.check()
        self.assert_fails_with(result, "remove svc.py::gone from the allow-list")
        self.assertIn("remove missing.py::f from the allow-list", result.stdout)

    def test_listed_count_is_exact(self) -> None:
        self.source(
            "svc.py",
            """
            async def fail(db):
                await commit_now(db, reason=Reason.SURVIVES_RAISE)
                await commit_now(db, reason=Reason.SURVIVES_RAISE)
            """,
        )
        self.allow("svc.py::fail 3 SURVIVES_RAISE")
        self.assert_fails_with(self.check(), "decrement its count to 2")
        self.allow("svc.py::fail 1 SURVIVES_RAISE")
        self.assert_fails_with(self.check(), "svc.py:4: add svc.py::fail to the allow-list")
        self.allow("svc.py::fail 2 SURVIVES_RAISE")
        self.assert_passes(self.check())

    def test_custom_helper_name(self) -> None:
        self.source("svc.py", "def f(db):\n    own_commit(db, reason=1)\n")
        self.allow("svc.py::f")
        self.assert_passes(self.check("--helper", "own_commit"))

    # Excludes

    def test_default_excludes_honoured(self) -> None:
        for rel in ("tests/test_svc.py", "migrations/0001.py", "app/alembic/env.py", ".venv/x.py"):
            self.source(rel, "def f(db):\n    db.commit()\n")
        self.assert_passes(self.check())

    def test_extra_exclude_by_name_and_glob(self) -> None:
        self.source("scripts/seed.py", "def f(db):\n    db.commit()\n")
        self.source("app/jobs/run.py", "def f(db):\n    db.commit()\n")
        self.assert_fails_with(self.check(), "raw commit on borrowed session db")
        self.assert_passes(self.check("--exclude", "scripts", "--exclude", "app/jobs/*"))

    # Input errors

    def test_malformed_allowlist_is_usage_error(self) -> None:
        self.allow("svc.py stamp")
        result = self.check()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("expected `<path>::<qualname>", result.stderr)

    def test_duplicate_allowlist_entry_is_usage_error(self) -> None:
        self.allow("svc.py::f", "svc.py::f")
        result = self.check()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("duplicate entry svc.py::f", result.stderr)

    def test_unparsable_source_is_usage_error(self) -> None:
        self.source("svc.py", "def broken(:\n")
        result = self.check()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("cannot parse", result.stderr)

    def test_missing_allowlist_is_usage_error(self) -> None:
        self.allowlist.unlink()
        self.assertEqual(self.check().returncode, 2)


if __name__ == "__main__":
    unittest.main()
