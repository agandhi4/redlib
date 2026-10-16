#!/usr/bin/env node
// Shared duplication collector: jscpd over the given paths, as ratchet keys.
//
// One line in scripts/ci/metrics.conf, run from the repo root, for example:
//   dup repo node devkit/metrics/jscpd.mjs --scope repo --out build/metrics/dup.json backend/server frontend/src
//
// Usage: jscpd.mjs --scope <name> [--min-tokens 50] [--min-lines 5] [--bin <jscpd>] [--base] [--out FILE] <paths...>
//   paths        repo-relative directories or files jscpd scans (at least one)
//   --min-tokens, --min-lines   jscpd's clone size knobs (its defaults are 50 and 5). The one
//                knob that moves the percentage: a repo that changes it rebaselines
//   --bin        the jscpd to run; default node_modules/.bin/jscpd under the current directory
//                (a repo whose frontend holds the dev dependencies passes
//                --bin frontend/node_modules/.bin/jscpd). Never PATH's: the lockfile's measures
// A `.jscpd.json` in the current directory is honoured by jscpd itself (ignore patterns,
// formats); the flags above override its matching keys, as jscpd's own CLI does.
//   --base       merge that `.jscpd.json` (or package.json `jscpd`) over devkit/lint/jscpd.base.json
//                (tests and `*.d.ts` out; lists union, the repo's scalars win) and pass the result
//                as jscpd's --config, which replaces the `.jscpd.json` lookup (lint/README.md)
//
// Keys (docs/metrics-keys.md, direction lower):
//   duplication.<scope>.jscpd_percent   duplicated lines over scanned lines: jscpd's own
//                                       statistics.total.percentage, rounded to the two decimals
//                                       its console reporter prints (the JSON carries the raw float)
//   duplication.<scope>.clones          clone pairs found (statistics.total.clones)
// Exit: 0 ok, 2 a missing jscpd, a report that cannot be read or a bad call.
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";

import { CollectorError, SCOPE, fail, ownConfig, parseJson, runTool, withMergedConfig, writeOutput } from "./_lib.mjs";

const SCRIPT = "jscpd.mjs";

function parse(argv) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      scope: { type: "string" },
      "min-tokens": { type: "string", default: "50" },
      "min-lines": { type: "string", default: "5" },
      bin: { type: "string", default: join("node_modules", ".bin", "jscpd") },
      base: { type: "boolean", default: false },
      out: { type: "string" },
    },
  });
  if (!values.scope || !SCOPE.test(values.scope)) {
    throw new CollectorError("--scope is required and must match [A-Za-z0-9_-]+");
  }
  for (const key of ["min-tokens", "min-lines"]) {
    if (!/^[1-9][0-9]*$/.test(values[key])) throw new CollectorError(`--${key} must be a positive integer`);
  }
  if (positionals.length === 0) throw new CollectorError("pass at least one path to scan");
  for (const p of positionals) {
    if (!existsSync(p)) throw new CollectorError(`path ${p} does not exist (paths are relative to the repo root)`);
  }
  return { ...values, paths: positionals };
}

function collect(opts) {
  if (!existsSync(opts.bin)) {
    throw new CollectorError(
      `jscpd is not installed at ${opts.bin}; add jscpd to the dev dependencies, or pass --bin <path>`,
    );
  }
  const outDir = mkdtempSync(join(tmpdir(), "devkit-jscpd-"));
  try {
    // jscpd exits 1 only with --threshold; still accepted so a repo's .jscpd.json may set one.
    const run = (extra) => runTool(resolve(opts.bin), [
      ...opts.paths,
      "--min-tokens", opts["min-tokens"],
      "--min-lines", opts["min-lines"],
      "--reporters", "json", "--output", outDir, "--no-colors",
      ...extra,
    ], { cwd: process.cwd() });
    if (opts.base) {
      const own = ownConfig(process.cwd(), { files: [".jscpd.json"], pkgKey: "jscpd" });
      withMergedConfig("jscpd.base.json", own, (path) => run(["--config", path]));
    } else {
      run([]);
    }
    const reportPath = join(outDir, "jscpd-report.json");
    if (!existsSync(reportPath)) throw new CollectorError("jscpd wrote no jscpd-report.json");
    const report = parseJson(readFileSync(reportPath, "utf8"), "jscpd report");
    const total = report?.statistics?.total;
    if (typeof total?.percentage !== "number" || typeof total?.clones !== "number") {
      throw new CollectorError("jscpd report has no statistics.total.percentage/clones");
    }
    return {
      [`duplication.${opts.scope}.jscpd_percent`]: Number(total.percentage.toFixed(2)),
      [`duplication.${opts.scope}.clones`]: total.clones,
    };
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
}

try {
  const opts = parse(process.argv.slice(2));
  writeOutput(collect(opts), opts.out);
} catch (err) {
  if (err instanceof CollectorError || err.code === "ERR_PARSE_ARGS_UNKNOWN_OPTION" || err.code === "ERR_PARSE_ARGS_INVALID_OPTION_VALUE") {
    fail(SCRIPT, err.message);
  }
  throw err;
}
