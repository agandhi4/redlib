// vitest's per-test timeouts, stretched by the machine load the way gate and tier budgets are.
//
// Why (finplat #689, 2026-10-19): frontend-unit hit vitest's 5 s testTimeout at a load of 169
// on 10 cores, while the tier's own budget had already stretched ×2. local_gate.sh (per job) and
// tier_guard.sh (per tier) export the factor they applied as DEVKIT_LOAD_SCALE; this module reads
// it once, when vitest loads the config. Unset, junk or <= 1 reads as 1, and it is capped at 2
// like the budgets (bin/_load_lib.sh), so a test that really doubled still fails on a busy box.
//
// Gotcha: imports nothing, like eslint.base.mjs and for the same reason: it is vendored at
// <repo>/devkit/lint/, whose ancestors hold no node_modules when package.json is in a subdirectory.
//
//   import { clockShiftSetupFiles, loadScaled, timeouts } from "../devkit/lint/vitest.base.mjs";
//   test: { ...timeouts, include: [...] }          vitest's defaults (5 s, 10 s), stretched
//   test: { testTimeout: loadScaled(180_000) }     a repo's own timeout, stretched
//   test: { setupFiles: [...clockShiftSetupFiles, "./src/test/setup.ts"] }
//
// clockShiftSetupFiles: the clock shift's setup file (clock_shift/vitest_clock_shift.mjs) when
// tier_guard.sh runs the tier under DEVKIT_CLOCK_SHIFT (it exports the file's path as
// DEVKIT_CLOCK_SHIFT_VITEST), else none. First in the root config's setupFiles, so the repo's own
// setup files run shifted; a project with `extends: true` inherits it ahead of its own.

const raw = Number(process.env.DEVKIT_LOAD_SCALE);
export const loadScale = Number.isFinite(raw) && raw > 1 ? Math.min(raw, 2) : 1;

export function loadScaled(ms) {
  return Math.round(ms * loadScale);
}

export const timeouts = { testTimeout: loadScaled(5_000), hookTimeout: loadScaled(10_000) };

const clockShiftSetup = process.env.DEVKIT_CLOCK_SHIFT_VITEST;
export const clockShiftSetupFiles = clockShiftSetup ? [clockShiftSetup] : [];
