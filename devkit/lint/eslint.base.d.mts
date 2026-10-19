// Types for eslint.base.mjs, so a TypeScript flat config (eslint.config.ts) can import it.
//
// Gotcha: this file imports nothing, like the .mjs, and for the same reason: a type import of
// "eslint" resolves from devkit/lint/'s ancestors, where a repo whose package.json sits in a
// subdirectory has no node_modules. So the shapes are spelled out here: they are eslint's
// Linter.RuleEntry and Linter.RulesRecord, and the base's configs are a subset of Linter.Config.
// tests/templates/eslint-base.types.ts holds them assignable to eslint's own types (tsc in
// template-tests), and tests/lint_contract.bats holds this export list to the module's.
type Severity = 0 | 1 | 2 | "off" | "warn" | "error";
type RuleEntry = Severity | [Severity, ...unknown[]];
type RulesRecord = Record<string, RuleEntry>;

interface BaseConfig {
  name: string;
  rules: RulesRecord;
}

declare const base: BaseConfig[];
export default base;

export declare const sonarjsRules: RulesRecord;
export declare const sonarjsTestRules: RulesRecord;
export declare const sonarjsChangedRules: RulesRecord;
