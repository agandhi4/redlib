// Types for vitest.base.mjs, so a vitest.config.ts imports it with no declaration of its own.
// Imports nothing, like the .mjs; tests/lint_contract.bats holds this export list to the module's.
export declare const loadScale: number;
export declare function loadScaled(ms: number): number;
export declare const timeouts: { testTimeout: number; hookTimeout: number };
export declare const clockShiftSetupFiles: string[];
