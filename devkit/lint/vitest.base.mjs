// vitest's per-test timeouts, stretched by the machine load the way gate and tier budgets are.
//
// Why (finplat #689, 2026-10-19): frontend-unit hit vitest's 5 s testTimeout at a load of 169
// on 10 cores, while the tier's own budget had already stretched ×2. local_gate.sh (per job) and
// tier_guard.sh (per tier) export the factor they applied as DEVKIT_LOAD_SCALE; this module reads
// it once, when vitest loads the config. Unset, junk or <= 1 reads as 1, and it is capped at 2
// like the budgets (bin/_load_lib.sh), so a test that really doubled still fails on a busy box.
//
// Gotcha: imports nothing but node builtins (eslint.base.mjs: nothing), for the same reason: it
// is vendored at <repo>/devkit/lint/, whose ancestors hold no node_modules when
// package.json is in a subdirectory. So no vite import: clockShift() reads vite's resolved
// allow list instead of calling searchForWorkspaceRoot.
//
//   import { clockShift, loadScaled, timeouts } from "../devkit/lint/vitest.base.mjs";
//   test: { ...timeouts, include: [...] }          vitest's defaults (5 s, 10 s), stretched
//   test: { testTimeout: loadScaled(180_000) }     a repo's own timeout, stretched
//   plugins: [clockShift()]                        the clock shift, when tier_guard runs one
//
// clockShift(): when tier_guard.sh runs the tier under DEVKIT_CLOCK_SHIFT (it exports the setup
// file's path as DEVKIT_CLOCK_SHIFT_VITEST), a vite plugin that owns both halves of loading the
// shift's setup file (clock_shift/vitest_clock_shift.mjs); else no plugin. One export, so a
// config cannot list the file without allowing it (orbit #124, 2026-10-24):
// - setupFiles: puts the file first, so the repo's own setup files run shifted. On vitest 3/4
//   the hook runs for the root and for every project with `extends: true` (which inherits the
//   plugin), so a project's own setupFiles get it ahead of them too; a project without `extends`
//   is unshifted. On vitest 5 inline projects inherit the root's setupFiles, the file first.
// - server.fs.allow: adds the file to vite's resolved list (vite's default, the workspace root,
//   or the repo's own list), never narrowing it; fs.strict stays on. Without it, a package in a
//   subdirectory (orbit frontend/, finplat frontend/, locus web/) cannot load the file vendored
//   above it at ../devkit/: vitest 4 refuses it in a happy-dom/jsdom project ("Cannot find
//   module '/@fs/…'"), vitest 3 in every project ("Failed to load url"). The realpath, since
//   vite resolves the setup file through symlinks before checking it.

import { realpathSync } from "node:fs";

const raw = Number(process.env.DEVKIT_LOAD_SCALE);
export const loadScale = Number.isFinite(raw) && raw > 1 ? Math.min(raw, 2) : 1;

export function loadScaled(ms) {
  return Math.round(ms * loadScale);
}

export const timeouts = { testTimeout: loadScaled(5_000), hookTimeout: loadScaled(10_000) };

const clockShiftSetup = process.env.DEVKIT_CLOCK_SHIFT_VITEST;

// Deprecated 2026-10-24 (lint/exports.txt; devkit-check warns on its use): the setup file alone,
// as before clockShift(). A config listing it must allow the file past fs.strict itself (orbit's
// local server.fs.allow). Kept so a repo-owned config keeps working across the sync that brought
// clockShift(); with both, the plugin's dedupe leaves the file listed once.
export const clockShiftSetupFiles = clockShiftSetup ? [clockShiftSetup] : [];

export function clockShift() {
  if (!clockShiftSetup) return [];
  const allowed = realpathSync(clockShiftSetup);
  return [
    {
      name: "devkit:clock-shift",
      // vitest 5 resolves inline projects on the root's vite server from `test` as its own
      // pre-ordered `config` hook captured it (sharedViteServer), never re-running plugins per
      // project: a normal-order hook adds the file after that capture, so no project ran it.
      // A user plugin's pre hook runs before vitest's own (vite lists config plugins first).
      enforce: "pre",
      config: {
        order: "pre",
        handler(config) {
          const test = (config.test ??= {});
          const own = [test.setupFiles ?? []].flat().filter((file) => file !== clockShiftSetup);
          test.setupFiles = [clockShiftSetup, ...own];
        },
      },
      configResolved(config) {
        const { allow } = config.server.fs;
        if (!allow.includes(allowed)) allow.push(allowed);
      },
    },
  ];
}
