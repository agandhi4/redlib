#!/usr/bin/env node
// Shared duplication collector: jscpd over the given paths, as ratchet keys.
//
// One line in scripts/ci/metrics.conf, run from the repo root, for example:
//   dup repo node devkit/metrics/jscpd.mjs --scope repo --out build/metrics/dup.json backend/server frontend/src
//
// Usage: jscpd.mjs --scope <name> [--min-tokens 50] [--min-lines 5] [--bin <jscpd>] [--base] [--format <f,...>] [--out FILE]
//                  [--list-out FILE] <paths...>
//   paths        repo-relative directories or files jscpd scans (at least one)
//   --min-tokens, --min-lines   jscpd's clone size knobs (its defaults are 50 and 5). The one
//                knob that moves the percentage: a repo that changes it rebaselines
//   --bin        the jscpd to run, from a repo's own lockfile (a repo whose frontend holds the
//                dev dependencies passes --bin frontend/node_modules/.bin/jscpd). Default:
//                devkit's pin (metrics/tools/package-lock.json, installed once per machine by
//                bin/npm_tool.sh), so a shell, Python, Swift or Rust repo needs no node project
//                of its own. Until 2026-11-25 a missing --bin with ./node_modules/.bin/jscpd
//                present still runs that one, with a DEPRECATED line (closet, rollcall: pass
//                --bin node_modules/.bin/jscpd, or drop jscpd from package.json). Never PATH's
// A `.jscpd.json` in the current directory is honoured by jscpd itself (ignore patterns,
// formats); the flags above override its matching keys, as jscpd's own CLI does.
//   --format     only these jscpd formats (its --format; `jscpd --list` names them). A shell
//                scope passes `--format bash`, which jscpd reads from .sh and .bash files: shell
//                needs no collector of its own. Extensionless scripts (git hooks) are not read,
//                as jscpd selects files by extension. Default: every format jscpd knows
//   --base       merge that `.jscpd.json` (or package.json `jscpd`) over devkit/lint/jscpd.base.json
//                (tests and `*.d.ts` out; lists union, the repo's scalars win) and pass the result
//                as jscpd's --config, which replaces the `.jscpd.json` lookup (lint/README.md)
//
// Keys (docs/metrics-keys.md, direction lower):
//   duplication.<scope>.jscpd_percent   duplicated lines over scanned lines: jscpd's own
//                                       statistics.total.percentage, rounded to the two decimals
//                                       its console reporter prints (the JSON carries the raw float)
//   duplication.<scope>.clones          clone pairs found (statistics.total.clones)
//
// --list-out FILE: the clone pairs behind `clones` (_lib.mjs writeFindings, ts.mjs's format),
// one line per pair, largest first: `<fileA>:<start>-<end> ↔ <fileB>:<start>-<end> lines=<n>`,
// paths relative to the working directory, the pair's two ends in path order. Never read by the
// ratchet; the JSON is the same with or without it.
// Exit: 0 ok, 3 a missing jscpd, 2 a report that cannot be read or a bad call.
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import {
  CollectorError,
  MissingToolError,
  SCOPE,
  fail,
  ownConfig,
  parseJson,
  runTool,
  withMergedConfig,
  writeFindings,
  writeOutput,
} from "./_lib.mjs";

const SCRIPT = "jscpd.mjs";
const NPM_TOOL = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "npm_tool.sh");
const LEGACY_BIN = join("node_modules", ".bin", "jscpd");

function parse(argv) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      scope: { type: "string" },
      "min-tokens": { type: "string", default: "50" },
      "min-lines": { type: "string", default: "5" },
      bin: { type: "string" },
      base: { type: "boolean", default: false },
      format: { type: "string" },
      out: { type: "string" },
      "list-out": { type: "string" },
    },
  });
  if (!values.scope || !SCOPE.test(values.scope)) {
    throw new CollectorError("--scope is required and must match [A-Za-z0-9_-]+");
  }
  for (const key of ["min-tokens", "min-lines"]) {
    if (!/^[1-9][0-9]*$/.test(values[key])) throw new CollectorError(`--${key} must be a positive integer`);
  }
  if (values.format !== undefined && !/^[a-z0-9-]+(,[a-z0-9-]+)*$/.test(values.format)) {
    throw new CollectorError("--format must be jscpd format names, comma-separated (jscpd --list)");
  }
  if (positionals.length === 0) throw new CollectorError("pass at least one path to scan");
  for (const p of positionals) {
    if (!existsSync(p)) throw new CollectorError(`path ${p} does not exist (paths are relative to the repo root)`);
  }
  return { ...values, paths: positionals };
}

// jscpdBin: --bin's, else (the deprecation window, header) the repo's own default install, else
// devkit's pin through bin/npm_tool.sh, which installs it on a cold machine.
function jscpdBin(bin) {
  if (bin !== undefined) {
    if (!existsSync(bin)) {
      throw new MissingToolError(`jscpd is not installed at ${bin}; install the repo's dev dependencies, or drop --bin for devkit's pin`);
    }
    return bin;
  }
  if (existsSync(LEGACY_BIN)) {
    process.stderr.write(
      `metrics/${SCRIPT}: DEPRECATED (until 2026-11-25): no --bin ran ./${LEGACY_BIN}; pass --bin ${LEGACY_BIN} to keep the repo's pin, or drop jscpd from package.json for devkit's\n`,
    );
    return LEGACY_BIN;
  }
  const run = spawnSync("bash", [NPM_TOOL, "jscpd", "--path"], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
  if (run.status !== 0) throw new MissingToolError(`devkit's pinned jscpd could not be provided (bin/npm_tool.sh exit ${run.status})`);
  return run.stdout.trim();
}

function collect(opts) {
  const bin = resolve(jscpdBin(opts.bin));
  const outDir = mkdtempSync(join(tmpdir(), "devkit-jscpd-"));
  try {
    // jscpd exits 1 only with --threshold; still accepted so a repo's .jscpd.json may set one.
    const run = (extra) => runTool(bin, [
      ...opts.paths,
      "--min-tokens", opts["min-tokens"],
      "--min-lines", opts["min-lines"],
      // --absolute: jscpd otherwise names a file relative to whichever scanned path holds it,
      // so src/a.ts and lib/a.ts both read `a.ts` in a finding.
      "--reporters", "json", "--output", outDir, "--no-colors", "--absolute",
      ...(opts.format === undefined ? [] : ["--format", opts.format]),
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
    const clonesKey = `duplication.${opts.scope}.clones`;
    return {
      keys: {
        [`duplication.${opts.scope}.jscpd_percent`]: Number(total.percentage.toFixed(2)),
        [clonesKey]: total.clones,
      },
      findings: { [clonesKey]: clonePairs(report) },
    };
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
}

// sourceOf: the file a duplicate end lives in. jscpd 5.4 names a block of a multi-format file
// `<path>:<format>` (a .vue's `<style>` is `A.vue:css`, lines still the file's), so a name that
// is not a file but whose prefix is keeps the format as a block suffix. Anything else is an error,
// never a silently dropped end.
function sourceOf(name) {
  if (existsSync(name)) return { source: name };
  const m = /^(.+):([A-Za-z0-9_-]+)$/.exec(name);
  if (m && existsSync(m[1])) return { source: m[1], block: m[2] };
  throw new CollectorError(`jscpd named a duplicate in ${name}, which is not a file`);
}

// clonePairs: the --list-out lines, largest clone first, then by path and line.
function clonePairs(report) {
  // Both sides real paths, as in ts.mjs: macOS's /var/folders is /private/var/folders, and a
  // relative path across that link would climb out of the repo.
  const cwd = realpathSync(process.cwd());
  if (!Array.isArray(report.duplicates)) throw new CollectorError("jscpd report has no `duplicates` array");
  const end = (file) => {
    if (typeof file?.name !== "string" || !Number.isInteger(file.start) || !Number.isInteger(file.end)) {
      throw new CollectorError(`unreadable jscpd duplicate end: ${JSON.stringify(file)}`);
    }
    const { source, block } = sourceOf(file.name);
    const path = relative(cwd, realpathSync(source)).split("\\").join("/");
    return { path: block === undefined ? path : `${path}:${block}`, start: file.start, end: file.end };
  };
  const byPlace = (x, y) => (x.path < y.path ? -1 : x.path > y.path ? 1 : x.start - y.start);
  return report.duplicates
    .map((d) => ({ lines: d.lines, ends: [end(d.firstFile), end(d.secondFile)].sort(byPlace) }))
    .sort((x, y) => y.lines - x.lines || byPlace(x.ends[0], y.ends[0]) || byPlace(x.ends[1], y.ends[1]))
    .map(({ lines, ends: [a, b] }) => `${a.path}:${a.start}-${a.end} ↔ ${b.path}:${b.start}-${b.end} lines=${lines}`);
}

try {
  const opts = parse(process.argv.slice(2));
  const { keys, findings } = collect(opts);
  writeOutput(keys, opts.out);
  if (opts["list-out"] !== undefined) writeFindings(findings, opts["list-out"]);
} catch (err) {
  if (err instanceof CollectorError || err.code === "ERR_PARSE_ARGS_UNKNOWN_OPTION" || err.code === "ERR_PARSE_ARGS_INVALID_OPTION_VALUE") {
    fail(SCRIPT, err);
  }
  throw err;
}
