# lint

`ruff.toml` is the shared ruff base (target py313, 100 columns, rules `E F I N W UP`). A consumer
replaces its own copies of those keys with one `extend` line, whose path is relative to the file
that contains it, and keeps only what names its own code: `src`, `exclude` and isort's
`known-first-party`. In locus (`pyproject.toml` at the root) that is
`[tool.ruff]` `extend = "devkit/lint/ruff.toml"` plus `[tool.ruff.lint.isort]`
`known-first-party = ["server"]`; finplat's `backend/pyproject.toml` sits one level down, so it
uses `extend = "../devkit/lint/ruff.toml"`. A key the consumer sets wins over the base, so
widening `select` locally is a visible diff, not a fork of the shared list.
