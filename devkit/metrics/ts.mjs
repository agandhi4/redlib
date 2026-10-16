#!/usr/bin/env node
// Shared TypeScript/JavaScript metrics collector: cyclomatic and cognitive complexity, dead
// code (knip), import cycles (dependency-cruiser) and bundle size (vite), as ratchet keys.
//
// One line in scripts/ci/metrics.conf, run from the repo root, for example:
//   ts-frontend frontend node devkit/metrics/ts.mjs --root frontend --src src --scope frontend \
//       --cyclomatic --cognitive --knip --cycles --bundle --out build/metrics/ts-frontend.json
//
// Usage: ts.mjs --root <dir> --src <subdir> --scope <name> [--out FILE]
//               [--tsconfig tsconfig.app.json] [--test-glob <glob>]...
//               [--cyclomatic] [--cognitive] [--knip [--knip-base]] [--cycles] [--bundle [--bundle-entry index.html]]
//   --root       the package: holds package.json and node_modules/.bin, where every tool comes
//                from (never PATH: the lockfile's version measures). A requested tool that is
//                not installed is exit 2 naming the dev dependency.
//   --src        the source directory under --root; its .ts/.tsx/.js/.jsx files minus tests
//                and `*.d.ts` are the production set the complexity rules and the graph see
//   --test-glob  what is a test or test scaffolding, besides the defaults below; repeatable.
//                Globs are relative to --src, `**` crosses directories, a bare `*.x` matches
//                at any depth
//   --tsconfig   for dependency-cruiser's path aliases (default tsconfig.app.json, then
//                tsconfig.json; none is fine for a project without aliases)
//
// Keys (docs/metrics-keys.md), each behind its flag; <scope> is --scope:
//   --cyclomatic complexity.<scope>.cyclomatic_max    eslint `complexity` rule at 0, injected
//                                                     from the CLI with --no-inline-config, so the
//                                                     repo's config and `eslint-disable` comments
//                                                     cannot hide a function
//   --cognitive  complexity.<scope>.cognitive_max     eslint-plugin-sonarjs cognitive-complexity
//                complexity.<scope>.cognitive_over_15 functions above 15 (SonarSource's threshold)
//   --knip       dead.<scope>.knip_exports            unused exports and exported types
//                dead.<scope>.knip_files              unused files
//                dead.<scope>.knip_deps               unused, unlisted and unresolved dependencies
//                                                     and binaries (knip reads the repo's knip
//                                                     config; `--directory <root>`)
//   --knip-base                                       with --knip: the repo's knip JSON(C) config
//                                                     (or package.json `knip`) merged over
//                                                     devkit/lint/knip.base.jsonc, passed as
//                                                     knip's --config (lists union, the repo's
//                                                     scalars win; lint/README.md)
//   --cycles     coupling.<scope>.cycles              dependency-cruiser's graph of --src
//                                                     (`--no-config`; tests excluded; `import type`
//                                                     is not an edge), strongly connected
//                                                     components of more than one module
//   --bundle     bundle.<scope>.kb_total              `vite build --manifest` into a throwaway
//                                                     outDir: every emitted file, raw KiB
//                bundle.<scope>.kb_entry              the entry chunk (--bundle-entry's manifest
//                                                     key, default index.html) plus its static
//                                                     import closure and their CSS: what the first
//                                                     screen loads. Dynamic imports are lazy pages
//                                                     and excluded. The build runs with a clean
//                                                     environment (PATH, HOME only), so values a
//                                                     vite `define` bakes in do not vary per machine
//
// Deterministic: same tree, same numbers (sorted inputs, no timings, no paths). Exit: 0 ok,
// 2 a missing tool, a report that cannot be read or a bad call.
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { parseArgs } from "node:util";

import {
  CollectorError,
  SCOPE,
  fail,
  globToRegExp,
  ownConfig,
  parseJson,
  requireBin,
  runTool,
  stronglyConnected,
  withMergedConfig,
  writeOutput,
} from "./_lib.mjs";

const SCRIPT = "ts.mjs";
const COGNITIVE_THRESHOLD = 15;
const SOURCE_EXT = /\.(ts|tsx|js|jsx|mts|cts|mjs|cjs)$/;
// Tests and scaffolding, as the fleet names them (finplat, Orbit, closet, rollcall); a repo
// adds its own with --test-glob.
const DEFAULT_TEST_GLOBS = [
  "*.test.*",
  "*.spec.*",
  "**/__tests__/**",
  "**/__mocks__/**",
  "**/test-helpers/**",
  "test-setup.*",
  "setupTests.*",
];
const ESLINT_COMPLEXITY = /^(?<name>.+?) has a complexity of (?<cx>\d+)\./;
const SONAR_COMPLEXITY = /Cognitive Complexity from (?<cx>\d+) to the/;

function parse(argv) {
  const { values } = parseArgs({
    args: argv,
    options: {
      root: { type: "string" },
      src: { type: "string" },
      scope: { type: "string" },
      out: { type: "string" },
      tsconfig: { type: "string" },
      "test-glob": { type: "string", multiple: true, default: [] },
      cyclomatic: { type: "boolean", default: false },
      cognitive: { type: "boolean", default: false },
      knip: { type: "boolean", default: false },
      "knip-base": { type: "boolean", default: false },
      cycles: { type: "boolean", default: false },
      bundle: { type: "boolean", default: false },
      "bundle-entry": { type: "string", default: "index.html" },
    },
  });
  if (!values.root || !existsSync(join(values.root, "package.json"))) {
    throw new CollectorError("--root must name a directory holding package.json");
  }
  if (!values.src || !existsSync(join(values.root, values.src))) {
    throw new CollectorError("--src must name a directory under --root");
  }
  if (!values.scope || !SCOPE.test(values.scope)) {
    throw new CollectorError("--scope is required and must match [A-Za-z0-9_-]+");
  }
  if (!(values.cyclomatic || values.cognitive || values.knip || values.cycles || values.bundle)) {
    throw new CollectorError("nothing to collect: pass --cyclomatic, --cognitive, --knip, --cycles or --bundle");
  }
  if (values["knip-base"] && !values.knip) throw new CollectorError("--knip-base needs --knip");
  if (values.tsconfig === undefined) {
    values.tsconfig = ["tsconfig.app.json", "tsconfig.json"].find((f) => existsSync(join(values.root, f)));
  } else if (!existsSync(join(values.root, values.tsconfig))) {
    throw new CollectorError(`--tsconfig ${values.tsconfig} is not under --root`);
  }
  return values;
}

// productionFiles: sorted paths relative to --root (`src/a/b.ts`) of the files the complexity
// rules see: sources under --src minus tests, scaffolding and declaration files.
function productionFiles(opts) {
  const tests = [...DEFAULT_TEST_GLOBS, ...opts["test-glob"]].map(globToRegExp);
  const srcDir = join(opts.root, opts.src);
  const found = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== "node_modules") walk(path);
        continue;
      }
      if (!entry.isFile() || !SOURCE_EXT.test(entry.name) || entry.name.endsWith(".d.ts")) continue;
      const rel = relative(srcDir, path).split("\\").join("/");
      if (tests.some((re) => re.test(rel))) continue;
      found.push(`${opts.src}/${rel}`);
    }
  };
  walk(srcDir);
  if (found.length === 0) throw new CollectorError(`no production source files under ${srcDir}`);
  return found;
}

// eslintFindings: one number per function the rule reported, over the production files only.
// The repo's own config still loads (parser, plugins); the rule comes from the CLI.
function eslintFindings(opts, files, extraArgs, ruleId, pattern) {
  const eslint = requireBin(opts.root, "eslint", "eslint");
  const out = runTool(eslint, [...extraArgs, "--no-inline-config", "--format", "json", ...files], {
    cwd: opts.root,
  });
  const values = [];
  for (const report of parseJson(out, "eslint output")) {
    for (const msg of report.messages) {
      if (msg.fatal) throw new CollectorError(`eslint could not lint ${report.filePath}: ${msg.message}`);
      if (msg.ruleId !== ruleId) continue;
      const match = pattern.exec(msg.message);
      if (!match) throw new CollectorError(`unparseable ${ruleId} message: ${JSON.stringify(msg.message)}`);
      values.push(Number(match.groups.cx));
    }
  }
  return values;
}

function collectCyclomatic(opts, files) {
  const values = eslintFindings(
    opts, files, ["--rule", '{"complexity": ["warn", 0]}'], "complexity", ESLINT_COMPLEXITY,
  );
  return { [`complexity.${opts.scope}.cyclomatic_max`]: Math.max(0, ...values) };
}

function collectCognitive(opts, files) {
  if (!existsSync(join(opts.root, "node_modules", "eslint-plugin-sonarjs", "package.json"))) {
    throw new CollectorError(
      `eslint-plugin-sonarjs is not installed in ${opts.root}/node_modules; add it to the dev dependencies`,
    );
  }
  const values = eslintFindings(
    opts, files,
    ["--plugin", "sonarjs", "--rule", '{"sonarjs/cognitive-complexity": ["warn", 0]}'],
    "sonarjs/cognitive-complexity", SONAR_COMPLEXITY,
  );
  return {
    [`complexity.${opts.scope}.cognitive_max`]: Math.max(0, ...values),
    [`complexity.${opts.scope}.cognitive_over_${COGNITIVE_THRESHOLD}`]: values.filter((v) => v > COGNITIVE_THRESHOLD).length,
  };
}

// What knip reads as its config, in its own lookup order; the code forms cannot be merged.
const KNIP_CONFIGS = { files: ["knip.json", "knip.jsonc", ".knip.json", ".knip.jsonc"], pkgKey: "knip",
  scriptFiles: ["knip.ts", "knip.js", "knip.mts", "knip.mjs", "knip.config.ts", "knip.config.js"] };

function collectKnip(opts) {
  const knip = requireBin(opts.root, "knip", "knip");
  // knip resolves --directory against its cwd, so the absolute path is passed.
  const args = ["--directory", resolve(opts.root), "--no-progress", "--reporter", "json"];
  const run = (extra) => runTool(knip, [...args, ...extra], { cwd: opts.root });
  const out = opts["knip-base"]
    ? withMergedConfig("knip.base.jsonc", ownConfig(opts.root, KNIP_CONFIGS), (path) => run(["--config", path]))
    : run([]);
  const report = parseJson(out, "knip output");
  if (!Array.isArray(report?.issues)) throw new CollectorError("knip output has no `issues` array");
  const count = (kinds) =>
    report.issues.reduce(
      (n, issue) => n + kinds.reduce((m, kind) => m + (Array.isArray(issue[kind]) ? issue[kind].length : 0), 0),
      0,
    );
  return {
    [`dead.${opts.scope}.knip_exports`]: count(["exports", "types"]),
    // knip 6 reports an unused file as an issue whose `files` holds it; there is no top-level
    // `files` list any more, so reading one counted 0 forever.
    [`dead.${opts.scope}.knip_files`]: count(["files"]),
    [`dead.${opts.scope}.knip_deps`]: count(["dependencies", "devDependencies", "unlisted", "unresolved", "binaries"]),
  };
}

function collectCycles(opts) {
  const depcruise = requireBin(opts.root, "depcruise", "dependency-cruiser");
  const args = [
    opts.src, "--no-config", "--include-only", `^${escapeForRegExp(opts.src)}`,
    "--output-type", "json",
  ];
  if (opts.tsconfig) args.push("--ts-config", opts.tsconfig);
  // No rules under --no-config, so a non-zero exit is an error, not a finding.
  const out = runTool(depcruise, args, { cwd: opts.root, ok: [0] });
  const report = parseJson(out, "dependency-cruiser output");
  if (!Array.isArray(report?.modules)) throw new CollectorError("dependency-cruiser output has no `modules`");
  // Tests, scaffolding and declaration files leave the graph here, with the same glob matcher
  // as the complexity file set: dependency-cruiser's --exclude refuses a regex with nested
  // repetition as "probably very slow", which every `**` glob becomes.
  const tests = [...DEFAULT_TEST_GLOBS, ...opts["test-glob"], "**/*.d.ts"].map(globToRegExp);
  const isProduction = (module) => {
    const rel = module.startsWith(`${opts.src}/`) ? module.slice(opts.src.length + 1) : null;
    return rel !== null && !tests.some((re) => re.test(rel));
  };
  const graph = new Map();
  for (const module of report.modules) {
    if (isProduction(module.source)) graph.set(module.source, new Set(module.dependencies.map((d) => d.resolved)));
  }
  for (const [module, imports] of graph) {
    graph.set(module, new Set([...imports].filter((t) => graph.has(t) && t !== module)));
  }
  return { [`coupling.${opts.scope}.cycles`]: stronglyConnected(graph).length };
}

function escapeForRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function kib(bytes) {
  return Number((bytes / 1024).toFixed(1));
}

function collectBundle(opts) {
  const vite = requireBin(opts.root, "vite", "vite");
  const dist = mkdtempSync(join(tmpdir(), "devkit-vite-"));
  try {
    runTool(vite, ["build", "--outDir", dist, "--emptyOutDir", "--manifest"], {
      cwd: opts.root,
      env: { PATH: process.env.PATH, HOME: process.env.HOME },
      ok: [0],
    });
    const manifestPath = join(dist, ".vite", "manifest.json");
    if (!existsSync(manifestPath)) throw new CollectorError("vite build wrote no .vite/manifest.json");
    const manifest = parseJson(readFileSync(manifestPath, "utf8"), "vite manifest");
    let entry = opts["bundle-entry"];
    if (!manifest[entry]?.isEntry) {
      const entries = Object.keys(manifest).filter((k) => manifest[k].isEntry);
      if (entries.length !== 1) {
        throw new CollectorError(
          `--bundle-entry ${entry} is not an entry in the vite manifest (entries: ${entries.join(", ") || "none"})`,
        );
      }
      [entry] = entries;
    }
    const seen = new Set();
    const stack = [entry];
    while (stack.length > 0) {
      const key = stack.pop();
      if (seen.has(key)) continue;
      seen.add(key);
      stack.push(...(manifest[key]?.imports ?? []));
    }
    const entryFiles = new Set();
    for (const key of seen) {
      entryFiles.add(manifest[key].file);
      for (const css of manifest[key].css ?? []) entryFiles.add(css);
    }
    let total = 0;
    const walk = (dir) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) {
          if (path !== join(dist, ".vite")) walk(path);
        } else total += statSync(path).size;
      }
    };
    walk(dist);
    const entryBytes = [...entryFiles].reduce((n, f) => n + statSync(join(dist, f)).size, 0);
    return {
      [`bundle.${opts.scope}.kb_total`]: kib(total),
      [`bundle.${opts.scope}.kb_entry`]: kib(entryBytes),
    };
  } finally {
    rmSync(dist, { recursive: true, force: true });
  }
}

function collect(opts) {
  const out = {};
  const files = opts.cyclomatic || opts.cognitive ? productionFiles(opts) : [];
  if (opts.cyclomatic) Object.assign(out, collectCyclomatic(opts, files));
  if (opts.cognitive) Object.assign(out, collectCognitive(opts, files));
  if (opts.knip) Object.assign(out, collectKnip(opts));
  if (opts.cycles) Object.assign(out, collectCycles(opts));
  if (opts.bundle) Object.assign(out, collectBundle(opts));
  return out;
}

try {
  const opts = parse(process.argv.slice(2));
  writeOutput(collect(opts), opts.out);
} catch (err) {
  if (err instanceof CollectorError || (typeof err.code === "string" && err.code.startsWith("ERR_PARSE_ARGS"))) {
    fail(SCRIPT, err.message);
  }
  throw err;
}
