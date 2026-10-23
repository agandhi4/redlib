"""pytest plugin: run the suite with the wall clock shifted DEVKIT_CLOCK_SHIFT days ahead.

Why (finplat #706, 2026-10-22): a test dated its lots from the real clock at import and pinned
the services' clock to a fixed day; it passed for 30 days, then failed every gate at midnight.
Rerunning a fast tier with the clock a month and a year ahead fails such a test the day it is
written. devkit/bin/tier_guard.sh loads this module (PYTEST_PLUGINS, with its directory on
PYTHONPATH) when DEVKIT_CLOCK_SHIFT=<n>d is set; the gate's CLOCK group sets it per offset
(devkit/bin/_paths_lib.sh). No repo code: the project needs only time-machine in its dev
dependencies.

The shift starts before the initial conftests load, so a module-level `NOW = datetime.now()`
in a conftest or test module is shifted too, and it ticks. Every xdist worker loads the plugin
from the same environment and shifts itself. time-machine moves the process's clock only: a
database's now(), another container's clock and monotonic timers stay real.

Exceptions: DEVKIT_CLOCK_SHIFT_CONF (tier_guard: <repo>/scripts/ci/clock_shift.conf), one
`<node id>  # <reason>` per line, node ids relative to pytest's rootdir. An entry covers the
node it names and everything under it (a directory, a module, a test and its parameters). Each
covered test still runs, as a non-strict xfail with the reason, so the tier's floor count holds
and an XPASS shows an exception that is no longer needed. A line without a reason is a usage
error: an exception is a decision, and the reason is its record.

Proof (an API): every process that starts the shift (the controller and each xdist worker)
appends `pytest +<n>d <pid>` to DEVKIT_CLOCK_SHIFT_PROOF, the file tier_guard reads; a shifted
tier with no such line ran on the real clock (NOSHIFT). The summary's `CLOCK-SHIFT pytest +<n>d`
line is for the reader. clock_shift/vitest_clock_shift.mjs is the vitest half, same contract.
"""

from __future__ import annotations

import os
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

try:
    import time_machine
except ModuleNotFoundError as err:
    raise ModuleNotFoundError(
        "devkit clock shift needs time-machine in the project's dev dependencies "
        "(uv add --dev time-machine)"
    ) from err

SHIFT_ENV = "DEVKIT_CLOCK_SHIFT"
CONF_ENV = "DEVKIT_CLOCK_SHIFT_CONF"
PROOF_ENV = "DEVKIT_CLOCK_SHIFT_PROOF"
SHIFT = re.compile(r"[1-9][0-9]*d")
_TRAVELLER = pytest.StashKey[time_machine.travel]()
_EXCEPTIONS = pytest.StashKey[list[tuple[str, str]]]()


def parse_shift(raw: str) -> timedelta:
    if not SHIFT.fullmatch(raw):
        raise pytest.UsageError(f"{SHIFT_ENV} must be whole days ahead, like 30d (got {raw!r})")
    return timedelta(days=int(raw[:-1]))


def load_exceptions(path: Path) -> list[tuple[str, str]]:
    """(node id, reason) per entry; no file is no exceptions."""
    if not path.is_file():
        return []
    entries: list[tuple[str, str]] = []
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        node, _, reason = line.partition("#")
        node, reason = node.strip(), reason.strip()
        # A node id may hold spaces (`test_window[New York]`); the first `#` starts the reason.
        if not node or not reason:
            raise pytest.UsageError(
                f"{path}:{n}: want `<node id>  # <reason>` (one node id, then why it is excepted)"
            )
        entries.append((node, reason))
    return entries


def covers(entry: str, nodeid: str) -> bool:
    """The entry is the node or an ancestor: a directory, a module, a class or a test whose
    parameters follow in brackets. `tests/test_a.py` does not cover `tests/test_ab.py`."""
    if nodeid == entry:
        return True
    return nodeid.startswith((entry.rstrip("/") + "/", entry + "::", entry + "["))


@pytest.hookimpl(tryfirst=True)
def pytest_load_initial_conftests(early_config: pytest.Config) -> None:
    raw = os.environ.get(SHIFT_ENV, "")
    if not raw:
        raise pytest.UsageError(
            f"devkit_clock_shift is loaded but {SHIFT_ENV} is unset; run the tier through "
            "devkit/bin/tier_guard.sh with DEVKIT_CLOCK_SHIFT=<n>d"
        )
    traveller = time_machine.travel(datetime.now(UTC) + parse_shift(raw), tick=True)
    traveller.start()
    early_config.stash[_TRAVELLER] = traveller
    if proof := os.environ.get(PROOF_ENV, ""):
        with Path(proof).open("a") as out:
            out.write(f"pytest +{raw} {os.getpid()}\n")
    conf = os.environ.get(CONF_ENV, "")
    early_config.stash[_EXCEPTIONS] = load_exceptions(Path(conf)) if conf else []


def pytest_unconfigure(config: pytest.Config) -> None:
    traveller = config.stash.get(_TRAVELLER, None)
    if traveller is not None:
        traveller.stop()


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    entries = config.stash.get(_EXCEPTIONS, [])
    for item in items:
        for entry, reason in entries:
            if covers(entry, item.nodeid):
                item.add_marker(
                    pytest.mark.xfail(reason=f"clock-shift exception: {reason}", strict=False)
                )
                break


def pytest_terminal_summary(
    terminalreporter: pytest.TerminalReporter, config: pytest.Config
) -> None:
    entries = config.stash.get(_EXCEPTIONS, [])
    terminalreporter.write_line(
        f"CLOCK-SHIFT pytest +{os.environ[SHIFT_ENV]} (wall clock {datetime.now(UTC):%Y-%m-%d}; "
        f"{len(entries)} exception(s) listed)"
    )
