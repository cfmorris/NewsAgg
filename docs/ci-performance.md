# CI performance: `checks` job timings and what we decided not to do

**Status: not scheduled.** The `checks` job takes about two minutes and that is
acceptable for now. This note records the measurements, the four options that
were considered, and the conditions that would make us revisit the decision, so
nobody has to re-measure before acting.

- **Measured on:** 2026-11-12 (UTC), run [`43150850556`](https://github.com/cfmorris/NewsAgg/actions/runs/43150850556), job `checks` (job id 130959369179), branch `codex/newsagg-25de3101407c4c478f0381821ecff150`, PR #21.
- **Source of the numbers:** per-step `started_at`/`completed_at` from the Actions jobs API, not the log scrollback.
- **Runner:** `windows-latest`, Ruby 4.0.9, Temurin Java 21, Neo4j 5.26.0 from the `actions/cache` distribution cache.

## Where the 124 seconds go

The `checks` job ran 03:50:31Z → 03:52:35Z: **124s wall (2m04s)**.

| Step | Seconds | Notes |
|---|---|---|
| Set up job | 2 | runner bootstrap |
| `actions/checkout@v6` | 5 | |
| `ruby/setup-ruby@v1` | 26 | `bundler-cache: true` — largest single step |
| `actions/setup-java@v6` | 1 | JDK already on the image |
| Cache disposable Neo4j distribution | 3 | cache hit |
| Check Ruby syntax | 3 | ~90 files through `ruby -c` |
| Prepare databases | 7 | `db:prepare` twice, default and `test` |
| 9 integration test steps | 38 | one process each, see below |
| Smoke test Rails routes | 3 | in-process Rack requests |
| Repeat-import integration test | 30 | downloads/starts disposable Neo4j 5.26.0 |
| Post steps and teardown | 3 | cache save, checkout cleanup |
| **Total accounted** | **121** | |
| Runner start/teardown outside any step | 3 | |
| **Wall clock** | **124** | |

The nine integration test steps, each its own `bundle exec ruby` process:

| Step | Seconds |
|---|---|
| Database | 3 |
| Authentication | 4 |
| Roles and admin area | 5 |
| Landing page and sign-in gate | 3 |
| Dashboard | 5 |
| Infographic | 3 |
| Ingestion | 3 |
| Auto-pull | 6 |
| Auto-pull budget and breaker | 6 |
| **Total** | **38** |

Two things fall out of the table:

- **~58s is fixed overhead** before any test asserts anything (set up, checkout, Ruby, Java, cache, syntax, `db:prepare`). Only parallel jobs or a faster runner image can compress that; no test-level change will.
- **~60s is actual test work**, of which `repeat-import` (30s) is a single step most of us never touch on a given PR.

## The four options

### A. Shard into three parallel jobs plus a thin aggregator

Three jobs each run the shared setup and then a third of the tests; a fourth
job named `checks` waits on all three and reports the required status.

- **Expected:** ~124s → ~60s (bounded by fixed setup plus the slowest shard).
- **Cost:** three Windows runners run concurrently per push. Free on a public repo; on a private repo this **triples** Windows minutes, which already bill at 2× Linux.
- **Risk:** the shard map is hand-maintained, so a new test file silently lands in no shard. The aggregator has to fail when any shard fails, or `checks` goes green over a red shard. Three Neo4j cache restores instead of one.

### B. Move `repeat-import` into its own job

Leave `checks` exactly as it is and run only the 30s Neo4j step as a second job.

- **Expected:** ~124s → ~94s for `checks`; PR wait becomes `max(94s, 30s + setup)`.
- **Cost:** one extra runner minute per push, no per-test maintenance.
- **Risk:** low. The one real requirement is that branch protection requires **both** `checks` and the new job — otherwise a failing repeat-import no longer blocks a merge. That is a settings change, not a YAML change, and is easy to forget.

### C. Run all integration tests in one Ruby process (rejected)

- **Expected:** ~20s saved (roughly 9 × ~2s of Ruby/Bundler boot).
- **Why rejected:** the per-test step names in the Actions UI are how the codepage failure was found — a single step named "Database, authentication, roles, dashboard, ingestion, auto-pull integration tests" tells you only that *something* failed, and the cheapest debugging tool we have in this repo goes away. Saving 20s is not worth losing that. Do not re-propose this without a replacement for per-test attribution.

### D. Port the job to `ubuntu-latest`

- **Expected:** wall time roughly unchanged (~110–120s) — the win is billing and the removal of PowerShell from the critical path, not seconds.
- **Cost:** Windows minutes bill at **2×** Linux on a private repo, so this halves the bill for the same job; option A's cost then drops from 6× to 3× Linux-equivalent.
- **Risk / work required:**
  1. Rewrite every `shell: pwsh` step as bash — the syntax check loop, `db:prepare`, the nine test steps, and the route smoke test's here-string.
  2. `bundle lock --add-platform x86_64-linux` and commit the updated `Gemfile.lock`, or `bundler-cache` fails on the Linux runner.
  3. Write a bash replacement for `test/support/neo4j-test.ps1` (it downloads and starts the disposable Neo4j server; a bash port needs to keep the `NEO4J_TEST_DISPOSABLE=1`, loopback-only and port-7474 guards).
  4. Re-pin the Neo4j cache key for the new OS.

## Verdict: not scheduled

124s is acceptable. The real cost is not the two minutes of compute — it is
delivery stalling while a PR sits with checks pending and then again while
someone reviews it. Shaving 60s helps only the first half of a wait that review
latency dominates, and every option that does it either triples billed minutes
(A) or gives up diagnostic granularity (C). Option B is the only cheap one, and
it is not worth the branch-protection change until the wait is actually hurting.

So: no sharding, no new jobs, no port. The workflow stays as it is.

## Revisit triggers

Re-open this decision when any of these is true:

1. **The repo goes private.** Option D becomes the first thing to do, before A or B — on a private repo Windows minutes bill at 2×, so D halves the bill immediately and makes A's real cost visible. Work order: D, then B if the wait still bites, then A last. Do not do A while still on Windows runners.
2. **Runs per day climb meaningfully.** Baseline at the time of writing was ~5 pushes/hour on an active afternoon (12 CI runs between 01:38Z and 03:53Z on 2026-11-12). Treat sustained ≥10 runs/hour, or >60 runs/day, as the point where per-run seconds start to matter.
3. **Median `checks` wall time crosses ~3 minutes.** That is a regression in setup, not noise — find what got slower before considering any option here.
4. **Someone has to touch the `pwsh` steps anyway.** If a PR already rewrites them, fold D into that PR instead of scheduling it separately.

## If the repo goes private, do this first

1. Add the Linux platform to the lockfile: `bundle lock --add-platform x86_64-linux`, commit `Gemfile.lock`.
2. Port `test/support/neo4j-test.ps1` to bash, preserving the disposable-server guards, and point the `Repeat-import integration test` step at it.
3. Rewrite the `pwsh` steps in `.github/workflows/ci.yml` as bash (`set -euo pipefail`; the syntax check becomes a `for` loop over `ruby -c`; the route smoke test's here-string becomes a heredoc piped to `bundle exec ruby`).
4. Switch `runs-on` to `ubuntu-latest` and re-pin the Neo4j cache key to `neo4j-test-Linux-...`.
5. Open it as one PR with the workflow change and the lockfile change together — a half-ported job fails at `bundler-cache`.
