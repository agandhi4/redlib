// Types for vitest.base.mjs, so a vitest.config.ts imports it with no declaration of its own.
// Imports nothing (vite's types do not resolve from devkit/lint/), so clockShift's return is typed
// structurally, as anything vite's `plugins` takes. tests/lint_contract.bats holds this export
// list to the module's.
export declare const loadScale: number;
export declare function loadScaled(ms: number): number;
export declare const timeouts: { testTimeout: number; hookTimeout: number };
export declare function clockShift(): { name: string }[];
/** @deprecated since 2026-10-24: use `plugins: [clockShift()]`, which also allows the file past fs.strict. */
export declare const clockShiftSetupFiles: string[];
