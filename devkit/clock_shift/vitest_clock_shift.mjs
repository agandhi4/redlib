// vitest setup file: run each test file with the wall clock DEVKIT_CLOCK_SHIFT days ahead, the
// vitest half of the clock shift (clock_shift/devkit_clock_shift.py is the pytest half; the why
// is there). devkit/bin/tier_guard.sh exports its path as DEVKIT_CLOCK_SHIFT_VITEST when the
// variable is set, and lint/vitest.base.mjs's clockShiftSetupFiles hands it to the repo's
// config, which lists it first in setupFiles, so the repo's own setup files are shifted too.
//
// Date is replaced by a proxy whose no-argument constructor, Date() call and Date.now() read the
// real clock plus the shift; it ticks, and timers, performance.now() and dates built from a value
// are untouched. Not vi.useFakeTimers({ toFake: ["Date"] }): vi.useRealTimers() in a test would
// drop the shift for the rest of the file, and closet and finplat call it in ~45 files. vitest's
// fake timers install over this proxy and restore it, and start from its shifted now. Like
// time-machine, it moves this process's clock only: a database's now() and a file's mtime stay
// real (closet's db tier: six age-based specs, 2026-10-22).
//
// Exceptions: DEVKIT_CLOCK_SHIFT_CONF (tier_guard: <repo>/scripts/ci/clock_shift.conf, shared
// with pytest), one `<test id>  # <reason>` per line, the id as vitest's failure line names the
// test: `<file relative to the vitest root> > <describe> > <test>`. An entry covers the test it
// names and everything under it (a directory, a file, a describe block). A covered test that
// fails is turned into a pass with a `clock-shift exception` line on stderr (shown by the default
// reporter; vitest 4.1's agent reporter, picked under an agent's env, hides a passing test's
// output), so the floor count holds; one that passes stays a pass (vitest has no XPASS to show). Non-strict, as pytest's: a
// test may rot at 365d and not at 30d. A line without a reason throws: the reason is the record.
//
// Gotchas: imports only node builtins and vitest, which vitest resolves for a setup file outside
// any node_modules tree (it is vendored at <repo>/devkit/clock_shift/, above web/'s packages).
// vitest 3 (vite 6) refuses to load a setup file outside its root's workspace ("Failed to load
// url ... Does the file exist?"), so a vitest-3 package in a subdirectory (instalite, locus web/)
// needs vitest 4+ or `server: { fs: { strict: false } }`; vitest 4.0-5.0 load it as is.
// The turn-around is afterEach setting task.fails, read by vitest's runner after the hooks; it is
// set on every attempt, so a covered test that passes on a retry is a pass. vi.setSystemTime()
// without fake timers, then vi.useRealTimers(), puts back vitest's own saved (real) Date: a
// beforeEach puts the proxy back over exactly that Date, never over a test's own fake one.
// Installs once per realm: a worker that keeps its globals across files (isolate: false) is
// shifted by its first file; the hooks register in every file. Only projects that inherit the
// root's setupFiles (`extends: true`) are shifted, and the proof cannot tell a project left out.
//
// Proof (tier_guard's NOSHIFT check, an API): each realm that installs the shift appends
// `vitest +<n>d <pid>` to DEVKIT_CLOCK_SHIFT_PROOF.
import { appendFileSync, existsSync, readFileSync } from "node:fs";

import { afterEach, beforeEach } from "vitest";

const raw = process.env.DEVKIT_CLOCK_SHIFT ?? "";
if (!/^[1-9][0-9]*d$/.test(raw)) {
  throw new Error(
    `devkit clock shift: DEVKIT_CLOCK_SHIFT must be whole days ahead, like 30d (got '${raw}'); ` +
      "run the tier through devkit/bin/tier_guard.sh",
  );
}
// The proxy answers this key with the real Date it wraps, so a later file in the same realm finds
// both.
const REAL = Symbol.for("devkit.clockShift.real");

function install() {
  const RealDate = globalThis.Date;
  const offset = Number(raw.slice(0, -1)) * 86_400_000;
  const now = () => RealDate.now() + offset;
  const shifted = new Proxy(RealDate, {
    construct: (target, args, newTarget) =>
      Reflect.construct(target, args.length > 0 ? args : [now()], newTarget),
    apply: () => new RealDate(now()).toString(),
    get: (target, key, receiver) => {
      if (key === "now") return now;
      if (key === REAL) return RealDate;
      return Reflect.get(target, key, receiver);
    },
  });
  globalThis.Date = shifted;
  const proof = process.env.DEVKIT_CLOCK_SHIFT_PROOF;
  if (proof) appendFileSync(proof, `vitest +${raw} ${process.pid}\n`);
  return shifted;
}

const shifted = globalThis.Date[REAL] ? globalThis.Date : install();
const realDate = shifted[REAL];
beforeEach(() => {
  if (globalThis.Date === realDate) globalThis.Date = shifted;
});

/** [test id, reason] per entry; no file is no exceptions. */
function loadExceptions(path) {
  if (!path || !existsSync(path)) return [];
  const entries = [];
  readFileSync(path, "utf8")
    .split("\n")
    .forEach((rawLine, i) => {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) return;
      const hash = line.indexOf("#");
      const id = (hash < 0 ? line : line.slice(0, hash)).trim();
      const reason = hash < 0 ? "" : line.slice(hash + 1).trim();
      if (!id || !reason) {
        throw new Error(
          `${path}:${i + 1}: want \`<test id>  # <reason>\` (one test id, then why it is excepted)`,
        );
      }
      entries.push([id, reason]);
    });
  return entries;
}

/** The entry is the test or an ancestor: a directory, a file or a describe block. */
function covers(entry, id) {
  return id === entry || id.startsWith(`${entry.replace(/\/$/, "")}/`) || id.startsWith(`${entry} > `);
}

function testId(task) {
  const names = [];
  for (let t = task; t && t !== task.file; t = t.suite) names.unshift(t.name);
  return [task.file.name, ...names].join(" > ");
}

const exceptions = loadExceptions(process.env.DEVKIT_CLOCK_SHIFT_CONF);
if (exceptions.length > 0) {
  afterEach(({ task }) => {
    const id = testId(task);
    const hit = exceptions.find(([entry]) => covers(entry, id));
    if (!hit) return;
    task.fails = task.result?.state === "fail";
    if (task.fails) console.warn(`clock-shift exception: ${id}: ${hit[1]}`);
  });
}
