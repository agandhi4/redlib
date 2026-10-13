# Decisions

Dated decisions and gotchas the code enforces but no doc explains. One entry per decision:
`## YYYY-MM-DD — title`, then **Why** / **Decision** / **Consequence**, at most eight lines.
Append in the same change as the code; standing rules go in the nearest `AGENTS.md` instead.

## __DATE__ — Created by `devkit new` (devkit __DEVKIT_SHA7__)
**Why**: a new repo must start at the fleet's bar, not re-invent it (standardization PLAN §1,
layer L5).
**Decision**: scaffolded with `devkit new __NAME__ --stack __STACK__`: vendored `devkit/`,
the standard `ci-*` Makefile, `scripts/ci/gate_plan.sh`, devkit's git hooks, the reusable
quick-check caller, Renovate's shared preset and this log. The first commit went through the
hooks, so `make ci-quick` and every devkit guard passed on it.
**Consequence**: deltas from the conventions are recorded under "Convention deltas" in
`AGENTS.md` with an entry here. Stub `ci-*` targets (exit 2) mark tiers this stack lacks.
