#!/usr/bin/env node
// Shared TypeScript/JavaScript metrics collector: cyclomatic and cognitive complexity, dead
// code (knip), import cycles (dependency-cruiser) and bundle size (vite), as ratchet keys.
//
// One line in scripts/ci/metrics.conf, run from the repo root, for example:
//   ts-frontend frontend node devkit/metrics/ts.mjs --root frontend --src src --scope frontend \
//       --cyclomatic --cognitive --knip --cycles --bundle --out build/metrics/ts-frontend.json
//
// Usage: ts.mjs --root <dir> --src <subdir> --scope <name> [--out FILE]
//               [--tsconfig tsconfig.app.json] [--test-glob <glob>]... [--list-out FILE]
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
//   --fan        coupling.<scope>.fan_in_max, .fan_out_max   the same graph: most importers of one module, most imports from one
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
// --list-out FILE: the findings behind the counts (metrics/python.py's format, written by
// _lib.mjs writeFindings): `# <key>`, then one line per finding; empty when there are none.
// Paths are --root joined with the root-relative path. Never read by the ratchet or the
// scorecard; the JSON is the same with or without it.
//   cyclomatic_max      <path>:<line> <function> cyclomatic=<n>, functions over 10 (McCabe's
//                       threshold in python.py), worst first
//   cognitive_over_15   <path>:<line> <function> cognitive=<n>, worst first; sonarjs names no
//                       function, so <function> is the identifier at the reported column
//                       (`<anonymous>` for an arrow or an unnamed `function` expression)
//   knip_exports, knip_files, knip_deps   <path>[:<line>] <name> <kind>
//   cycles              one line per cycle: its module files, space-separated, largest first
//   fan_in_max, fan_out_max   <path> fan_in=<n> | fan_out=<n>, the top 10 (FAN_TOP)
//
// Deterministic: same tree, same numbers (sorted inputs, no timings, no paths). Exit: 0 ok,
// 2 a missing tool, a report that cannot be read or a bad call.
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, posix, relative, resolve } from "node:path";
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
  writeFindings,
  writeOutput,
} from "./_lib.mjs";

const SCRIPT = "ts.mjs";
const COGNITIVE_THRESHOLD = 15;
const CYCLOMATIC_LIST_THRESHOLD = 10; // --list-out only: there is no cyclomatic_over key
const FAN_TOP = 10; // --list-out modules per fan key; the same in metrics/python.py
const ANONYMOUS = "<anonymous>"; // --list-out's name for a function the tool does not name
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
      "list-out": { type: "string" },
      tsconfig: { type: "string" },
      "test-glob": { type: "string", multiple: true, default: [] },
      cyclomatic: { type: "boolean", default: false },
      cognitive: { type: "boolean", default: false },
      knip: { type: "boolean", default: false },
      "knip-base": { type: "boolean", default: false },
      cycles: { type: "boolean", default: false },
      fan: { type: "boolean", default: false },
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
  if (!(values.cyclomatic || values.cognitive || values.knip || values.cycles || values.fan || values.bundle)) {
    throw new CollectorError("nothing to collect: pass --cyclomatic, --cognitive, --knip, --cycles, --fan or --bundle");
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

// shown: a root-relative path as a lane opens it (repo-relative in a gate run, cwd = repo root).
function shown(opts, rel) {
  return posix.join(opts.root, rel);
}

// eslintFindings: one { rel, line, column, score, match } per function the rule reported,
// over the production files only. The repo's own config still loads (parser, plugins); the
// rule comes from the CLI.
function eslintFindings(opts, files, extraArgs, ruleId, pattern) {
  const eslint = requireBin(opts.root, "eslint", "eslint");
  const out = runTool(eslint, [...extraArgs, "--no-inline-config", "--format", "json", ...files], {
    cwd: opts.root,
  });
  const found = [];
  // Both sides real paths: eslint may report a symlinked root's target (macOS /var/folders is
  // /private/var/folders), and a relative path across that link would climb out of the root.
  const root = realpathSync(opts.root);
  for (const report of parseJson(out, "eslint output")) {
    const rel = relative(root, realpathSync(report.filePath)).split("\\").join("/");
    for (const msg of report.messages) {
      if (msg.fatal) throw new CollectorError(`eslint could not lint ${report.filePath}: ${msg.message}`);
      if (msg.ruleId !== ruleId) continue;
      const match = pattern.exec(msg.message);
      if (!match) throw new CollectorError(`unparseable ${ruleId} message: ${JSON.stringify(msg.message)}`);
      found.push({ rel, line: msg.line, column: msg.column, score: Number(match.groups.cx), match });
    }
  }
  return found;
}

// worstFirst: the --list-out lines of the functions scoring over `threshold`, highest first.
function worstFirst(opts, found, threshold, metric, nameOf) {
  return found
    .filter((f) => f.score > threshold)
    .sort((x, y) => y.score - x.score || compare(x.rel, y.rel) || x.line - y.line)
    .map((f) => `${shown(opts, f.rel)}:${f.line} ${nameOf(f)} ${metric}=${f.score}`);
}

function compare(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function collectCyclomatic(opts, files) {
  const found = eslintFindings(
    opts, files, ["--rule", '{"complexity": ["warn", 0]}'], "complexity", ESLINT_COMPLEXITY,
  );
  const key = `complexity.${opts.scope}.cyclomatic_max`;
  // The rule's message names the function ("Method 'load' has ..."), or only its kind
  // ("Arrow function has ...").
  const nameOf = (f) => /'(?<name>[^']+)'/.exec(f.match.groups.name)?.groups.name ?? ANONYMOUS;
  return {
    keys: { [key]: Math.max(0, ...found.map((f) => f.score)) },
    findings: { [key]: worstFirst(opts, found, CYCLOMATIC_LIST_THRESHOLD, "cyclomatic", nameOf) },
  };
}

// identifierAt: sonarjs reports cognitive complexity on the function's name token, the
// `function` keyword of a function expression (`memo(function Row(`) or the `=>` of an arrow,
// and its message names no function, so the name is read from the source at the reported
// 1-based line and column. An inline arrow callback is <anonymous>; its line still locates it.
const NAME_AT = /^(?:function\s*\*?\s*)?(?<name>[A-Za-z_$][\w$]*)/;
function identifierAt(opts, rel, line, column, cache) {
  if (!cache.has(rel)) cache.set(rel, readFileSync(join(opts.root, rel), "utf8").split("\n"));
  const name = NAME_AT.exec((cache.get(rel)[line - 1] ?? "").slice(column - 1))?.groups.name;
  return name === undefined || name === "function" ? ANONYMOUS : name;
}

function collectCognitive(opts, files) {
  if (!existsSync(join(opts.root, "node_modules", "eslint-plugin-sonarjs", "package.json"))) {
    throw new CollectorError(
      `eslint-plugin-sonarjs is not installed in ${opts.root}/node_modules; add it to the dev dependencies`,
    );
  }
  const found = eslintFindings(
    opts, files,
    ["--plugin", "sonarjs", "--rule", '{"sonarjs/cognitive-complexity": ["warn", 0]}'],
    "sonarjs/cognitive-complexity", SONAR_COMPLEXITY,
  );
  const overKey = `complexity.${opts.scope}.cognitive_over_${COGNITIVE_THRESHOLD}`;
  const sources = new Map();
  const nameOf = (f) => identifierAt(opts, f.rel, f.line, f.column, sources);
  return {
    keys: {
      [`complexity.${opts.scope}.cognitive_max`]: Math.max(0, ...found.map((f) => f.score)),
      [overKey]: found.filter((f) => f.score > COGNITIVE_THRESHOLD).length,
    },
    findings: { [overKey]: worstFirst(opts, found, COGNITIVE_THRESHOLD, "cognitive", nameOf) },
  };
}

// What knip reads as its config, in its own lookup order; the code forms cannot be merged.
const KNIP_CONFIGS = { files: ["knip.json", "knip.jsonc", ".knip.json", ".knip.jsonc"], pkgKey: "knip",
  scriptFiles: ["knip.ts", "knip.js", "knip.mts", "knip.mjs", "knip.config.ts", "knip.config.js"] };

// Key suffix -> knip's issue kinds it counts -> the kind word --list-out prints.
const KNIP_KEYS = {
  knip_exports: { exports: "export", types: "type" },
  // knip 6 reports an unused file as an issue whose `files` holds it; there is no top-level
  // `files` list any more, so reading one counted 0 forever.
  knip_files: { files: "file" },
  knip_deps: {
    dependencies: "dependency", devDependencies: "devDependency", unlisted: "unlisted",
    unresolved: "unresolved", binaries: "binary",
  },
};

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
  const keys = {};
  const findings = {};
  for (const [suffix, kinds] of Object.entries(KNIP_KEYS)) {
    const found = [];
    for (const issue of report.issues) {
      for (const [kind, label] of Object.entries(kinds)) {
        for (const item of Array.isArray(issue[kind]) ? issue[kind] : []) {
          found.push({ path: shown(opts, issue.file), line: item.line, name: item.name, label });
        }
      }
    }
    found.sort((x, y) => compare(x.path, y.path) || (x.line ?? 0) - (y.line ?? 0) || compare(x.name, y.name));
    const key = `dead.${opts.scope}.${suffix}`;
    keys[key] = found.length;
    findings[key] = found.map((f) => `${f.path}${f.line === undefined ? "" : `:${f.line}`} ${f.name} ${f.label}`);
  }
  return { keys, findings };
}


// importGraph: production module -> the production modules it imports at runtime, from
// dependency-cruiser; shared by --cycles and --fan so both see one graph.
function importGraph(opts) {
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
  // A node is a production source file, the complexity file set's definition: SOURCE_EXT, no
  // tests, no declaration files, the same glob matcher (dependency-cruiser's --exclude refuses a
  // regex with nested repetition as "probably very slow", which every `**` glob becomes). A
  // stylesheet, an image or a `?raw`/`?url` import is an asset the bundler inlines, not a
  // module whose API the importer couples to, so it is no fan-out edge (orbit #82: a .css
  // import moved fan_out_max 23 -> 24).
  const tests = [...DEFAULT_TEST_GLOBS, ...opts["test-glob"], "**/*.d.ts"].map(globToRegExp);
  const isProduction = (module) => {
    const rel = module.startsWith(`${opts.src}/`) ? module.slice(opts.src.length + 1) : null;
    return rel !== null && SOURCE_EXT.test(rel) && !tests.some((re) => re.test(rel));
  };
  const graph = new Map();
  for (const module of report.modules) {
    if (isProduction(module.source)) graph.set(module.source, new Set(module.dependencies.map((d) => d.resolved)));
  }
  for (const [module, imports] of graph) {
    graph.set(module, new Set([...imports].filter((t) => graph.has(t) && t !== module)));
  }
  return graph;
}

function collectCycles(opts, graph) {
  const cycles = stronglyConnected(graph)
    .map((component) => component.map((m) => shown(opts, m)).sort())
    .sort((x, y) => y.length - x.length || compare(x.join(" "), y.join(" ")));
  const key = `coupling.${opts.scope}.cycles`;
  return { keys: { [key]: cycles.length }, findings: { [key]: cycles.map((c) => c.join(" ")) } };
}

// fan-in: the most importers one module has; fan-out: the most modules one module imports (a
// god module, scorecard T4). Same definition as metrics/python.py.
function collectFan(opts, graph) {
  const fanIn = new Map([...graph.keys()].map((m) => [m, 0]));
  for (const imports of graph.values()) for (const t of imports) fanIn.set(t, (fanIn.get(t) ?? 0) + 1);
  const fanOut = new Map([...graph].map(([m, imports]) => [m, imports.size]));
  const top = (counts, metric) =>
    [...counts]
      .filter(([, n]) => n > 0)
      .map(([m, n]) => [shown(opts, m), n])
      .sort(([pa, a], [pb, b]) => b - a || compare(pa, pb))
      .slice(0, FAN_TOP)
      .map(([path, n]) => `${path} ${metric}=${n}`);
  const inKey = `coupling.${opts.scope}.fan_in_max`;
  const outKey = `coupling.${opts.scope}.fan_out_max`;
  return {
    keys: { [inKey]: Math.max(0, ...fanIn.values()), [outKey]: Math.max(0, ...fanOut.values()) },
    findings: { [inKey]: top(fanIn, "fan_in"), [outKey]: top(fanOut, "fan_out") },
  };
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
      keys: { [`bundle.${opts.scope}.kb_total`]: kib(total), [`bundle.${opts.scope}.kb_entry`]: kib(entryBytes) },
      findings: {},
    };
  } finally {
    rmSync(dist, { recursive: true, force: true });
  }
}

// collect: every requested collector's { keys, findings } merged: keys are the JSON, findings
// (key -> --list-out lines) explain them.
function collect(opts) {
  const out = { keys: {}, findings: {} };
  const add = ({ keys, findings }) => {
    Object.assign(out.keys, keys);
    Object.assign(out.findings, findings);
  };
  const files = opts.cyclomatic || opts.cognitive ? productionFiles(opts) : [];
  if (opts.cyclomatic) add(collectCyclomatic(opts, files));
  if (opts.cognitive) add(collectCognitive(opts, files));
  if (opts.knip) add(collectKnip(opts));
  const graph = opts.cycles || opts.fan ? importGraph(opts) : null;
  if (opts.cycles) add(collectCycles(opts, graph));
  if (opts.fan) add(collectFan(opts, graph));
  if (opts.bundle) add(collectBundle(opts));
  return out;
}

try {
  const opts = parse(process.argv.slice(2));
  const { keys, findings } = collect(opts);
  writeOutput(keys, opts.out);
  if (opts["list-out"] !== undefined) writeFindings(findings, opts["list-out"]);
} catch (err) {
  if (err instanceof CollectorError || (typeof err.code === "string" && err.code.startsWith("ERR_PARSE_ARGS"))) {
    fail(SCRIPT, err.message);
  }
  throw err;
}
