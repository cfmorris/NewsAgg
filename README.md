# Technical Reading Room

Rails owns the dashboard: controllers and views render the archive, filter it, and
compute every article and topic count on the server. Turbo keeps the page current.
Ruby services own Hacker News intake, article fetching, DeepSeek summarization,
retries, and Neo4j imports; the Rails web process itself runs them on a schedule,
so no separate worker process is needed. No Node.js installation is required.

## Run locally

Install Ruby 3.2 or newer with Bundler and the RubyInstaller MSYS2 toolchain,
start your Neo4j instance, and run these commands from this directory in
PowerShell. Set the database and user for the archive if they differ from the
defaults. The import creates constraints and writes nodes with labels prefixed
by `News`.

```powershell
$env:BUNDLE_PATH = 'vendor/bundle'
ridk exec bundle install
$env:NEO4J_HTTP_URL = 'http://127.0.0.1:7474'
$env:NEO4J_DATABASE = 'neo4j'
$env:NEO4J_USER = 'neo4j'
$env:NEO4J_PASSWORD = Read-Host 'Neo4j password' -MaskInput
Get-Content -Raw db/first-digest.json | ruby bin/import-news
bundle exec puma -b tcp://127.0.0.1:3000
```

Open [the local site](http://127.0.0.1:3000/). The root path is a public landing
page; signing in takes you to the dashboard at `/dashboard`. Every other screen
needs a session, so keep the server bound to loopback as well.

The importer accepts a JSON array from standard input. Each row has a canonical
`url`, `title`, `summary`, `depth`, `publisher`, `topics` array, `source`,
`external_id`, and optional `discovery_url` and `published_date` (YYYY-MM-DD).
An optional `quality_score` (1-100) and `quality_status` are recorded with the
row; a row without one takes the documented default of 50 marked `default`, and
an off-scale number is clamped into 1..100 marked `clamped`.
A second discovery for the same canonical URL adds a discovery link and reuses
the original summary.

Source pollers for other sites and scheduled imports are pending.
The current queries use standard Cypher.

### Dashboard behavior

Search, date presets, date ranges, publisher, discovery source, technical depth,
and topic filters all run through `/` and are applied in Ruby by
`DashboardFilter`. The page renders inside a Turbo frame, so changing a filter
updates the article list, topic counts, and count heading without a full reload.
The browser only supplies interaction behavior: it submits filters, controls the
Auto-pull toggle, and polls the Turbo stream that announces new archive
versions. When a new version arrives while the page is scrolled or focused, the
dashboard offers **New articles available** instead of yanking the view.

The same archive also prints a front page at `/infographic`: a server-rendered
broadsheet with topic columns, the technical-depth mix, the publisher long tail,
and the oldest item on file. Every figure is in the HTML, so the page is
complete with JavaScript disabled.

### Automated Hacker News batch

The Ruby worker combines Hacker News intake, public article fetches, publisher
extraction, DeepSeek structured summaries and tags, and the Neo4j importer:

```powershell
$env:NEWSAGG_SUMMARY_PROVIDER = 'deepseek'
$env:DEEPSEEK_API_KEY = Read-Host 'DeepSeek API key' -MaskInput
ruby bin/ingest-hn --limit 10 --retry-file tmp/hn-retry.json
```

Auto-pull runs inside the web process, so `bundle exec puma -b tcp://127.0.0.1:3000`
is the only process to start. Auto-pull starts off. Turn it on beside **Date
added** and the server pulls a batch immediately, then every 60 seconds, until
you turn it off; a batch already running finishes, and the dashboard shows the
last pull time and any error beside the toggle. The toggle writes
`tmp/auto-pull.enabled`; the flag is an opt-in for the running process only, so
a restart clears it and Auto-pull starts off again (the server logs `Auto-pull
reset to off on boot`). A pid lock at `tmp/auto-pull-worker.lock` stops a second
web process on the same checkout from pulling alongside the first.

The supervisor boots from `config.ru`, so `rails runner` and the console never
start a puller. Set `NEWSAGG_AUTO_PULL=0` to keep the web process from pulling.

#### Source allowlist

`config/sources.yml` is the single explicit list of ingest sources. Every entry
declares `name`, `kind` (`rss` or `api`), `url`, `enabled`, `override`,
`max_items`, `min_words`, `domains`/`exclude_domains`, and `owner` (null for the
shared sources, an owner id for future per-owner paid ones). Three sources are listed and
enabled today: the Hacker News API, the Lobsters API, and The Software Analyst's
Substack feed.

`kind` picks the adapter. `api` entries are adapted only when their `url` is a
known API (Hacker News or Lobsters), and `rss` entries are read by `RssClient`, which parses RSS 2.0
and Atom into the same candidate shape the API adapter emits (`title`, `url`,
`source`, `external_id`, `discovery_url`, `submitted_at`, `score`). An item with
no `guid` is identified by its normalized URL, a relative link is resolved
against the feed URL, and repeated guids — inside one poll or across polls — are
skipped before the article is fetched. An enabled entry that no adapter can read
is reported as `has no adapter` and contributes nothing.

The file is parsed and validated at boot: a missing file, unknown or missing
`kind`, missing or non-http `url`, duplicate `name`, unknown key, or malformed
value aborts boot with the file path, the entry index, and the reason. There is
no built-in source and no discovery fallback — an unlisted source is never
fetched, and an empty `sources:` list yields an empty registry rather than a
default feed. Set `NEWSAGG_SOURCES_PATH` to load a different file.

Every candidate then passes the pre-fetch gate (`SourceGate`). It must name
a source that is in the allowlist and enabled, and its URL must satisfy that
entry's domain rules; otherwise it is dropped before anything is fetched for it.
The rule holds for links found inside a registered feed: a feed vouches only for
itself, so an embedded link labelled with an unlisted source is dropped. Disabled
entries are not polled at all, a candidate with no source is never attributed to
the feed that surfaced it, and the retry file is gated the same way, so removing
or disabling a source stops its backlog too. Each refusal is logged as
`source gate: dropped candidate source=... reason=... url=...` with a run summary,
and `last_result` carries the drop count and per-reason totals. A source whose
adapter fails — an unreachable or malformed feed — is logged as
`reason=adapter_failed` with the adapter's message and the rest of the run
continues.

The Lobsters adapter reads its allowlist entry's URL (one JSON poll, no per-item
requests) and yields the same candidate shape as Hacker News. A Lobsters
self-post has no external `url`: the candidate carries the `short_id_url`
discussion link and `fetch: false`, so the batch counts it as discussion-only
instead of fetching the discussion page as if it were an article. That skip is
reported in the run summary (`N discussion-only skipped`) and never becomes a
retry entry.

Every import also materialises the allowlist as one `NewsSource` node per entry
in Neo4j, identified by the entry's `id` (an optional explicit slug in
`config/sources.yml`, defaulting to the slugified `name`) and written with an
idempotent `MERGE`, so importing twice leaves exactly one node per source. The
`name` is the display label and follows config. Config owns the policy fields
(`kind`, `url`, `enabled`, `owner`, `max_items`, `min_words`, `domains`,
`exclude_domains`) plus the `override` flag and `override_keys` list that name
the settings departing from their defaults; the node owns the accumulated facts
`article_count`, `cost_usd` and `quality_score`, which are seeded at 0 on create
and preserved by the materialiser on every later sync — a re-sync never wipes
them.

`cost_usd` is derived, not incremented: after every import the archive
recomputes it as the sum of `summary_cost_usd` over the articles attributed to
that source (joined through `NewsDiscovery.source` = the `NewsSource` `name`).
Because the total is recomputed from the articles, replaying an import or
running the aggregation again cannot double-count, a null or zero article cost
contributes nothing, and an article discovered twice by the same source counts
once. Sources are matched without an `enabled` filter, so a source disabled in
config keeps the historical cost of the articles it already contributed.
`bin/recompute-source-costs` runs the same aggregation standalone as a backfill.

#### Source score and auto-pause

Each source is scored from its own articles, so "Hacker News" and a niche
Substack are not judged alike just because both are listed. `quality_score` is
the **decayed rolling average** of the source's article scores: in the list of
its scored articles ordered newest first, the newest carries weight 1.0, the
next 0.95, the next 0.95², and so on, and the score is the weighted mean. A
source's score therefore follows its recent output — five good pieces after a
long run of mediocre ones lift it — instead of being anchored by its whole
history. `article_count` is the size of that population (scored articles only;
an unscored legacy row neither drags the average down nor pads the count), and a
source with no scored articles has no score at all rather than a zero. Both
fields are recomputed from the articles after every import and by
`bin/recompute-source-scores`, so a replay produces the same numbers.

A source that is not worth paying for stops on its own. Once it has at least
**5** scored articles and its score is **below 40**, the scoring pass sets
`enabled = false` on its node and records why: `paused_at`, `paused_by = auto`,
and a `pause_reason` such as `auto-paused: quality score 31.0 over 5 articles is
below 40`. The pause is enforced before anything is fetched — the source is left
out of the adapter map and the pre-fetch `SourceGate` refuses it with
`reason=paused_source`. Two things keep the pause from being a trap:

- **`override: true` in `config/sources.yml`** exempts a source from the pause
  entirely, whatever it scores. It is materialised as `pause_override` and is a
  different flag from the node's `override`/`override_keys`, which report config
  departures.
- **The admin console can undo it.** `/admin/sources` lists every source with
  its status, decayed score, article count, accumulated cost and pause reason,
  and offers `Resume` on a paused one. Resuming clears the pause and restores
  what config says: a source still enabled in config fetches again on the next
  run, and one disabled in config stays off (the flash message says which).
  Nothing is ever deleted, so a resumed source keeps its articles, its score and
  its cost. Resume buys the source another run, not an exemption: the score only
  moves when it contributes new articles, so a resumed source that brings
  nothing new is paused again by the pass that scores that run. `override: true`
  is the way to keep a low-scoring source on indefinitely.

Pausing is about money, not history: `cost_usd` keeps accumulating from the
articles the source already contributed, and a queued retry that commits an
article for a paused source still counts. A re-sync from config does not
re-enable a paused source either — the config's own value is kept in
`configured_enabled`, and the effective `enabled` is
`configured_enabled AND not paused`.

#### Article quality score

Every summary also carries a **1-100 quality score**, so the dashboard can rank
articles instead of treating them as equally worth reading. The summarizer's
system prompt states the rubric the model must apply: 90-100 is a landmark
analysis, 70-89 specific and current, 50-69 ordinary coverage, 30-49 thin or
promotional, 1-29 filler. The score is returned in the same JSON object as the
summary, so it costs nothing extra.

The article stores it as `quality_score` (an integer on the 1-100 scale) beside
`quality_status`, which says where the number came from:

- `ok` — the model returned a score on the scale.
- `clamped` — the model returned a number outside the scale; it is clamped into
  1..100 rather than discarded (0 becomes 1, 101 becomes 100).
- `default` — the score was missing or not a number; the article takes the
  documented fallback of **50**, the midpoint, so it is neither promoted nor
  buried by a quality sort.

A clamp or fallback never fails a story: the substitution is logged as
`Article quality score ... is outside 1-100; clamped to ...` or `... recorded the
default of 50` alongside the run's other messages, and `quality_status` keeps it
visible in the data. Records replayed from an older retry file are normalized the
same way, so a batch written before scoring existed still imports.

Both fields are written on create only, next to `summary_cost_usd`, so
re-importing or re-scoring an article keeps the score and the cost the first
import paid for — a replay never double-charges.

`GET /articles` carries `quality_score` and `quality_status` on every row (null
for articles written before scoring existed). The dashboard shows `Quality 87`
on each article card, marked `(clamped)` or `(default)` when the value was
substituted, and the topic sidebar's **Sort** block offers `Newest first` and
`Highest quality`. The quality order puts the highest score first, keeps ties in
the archive's own order, and places unscored articles last.

#### Long-form chunking and the Long form tag

One summarizer request carries at most 12,000 characters
(`ArticleExtractor::MAX_TEXT`), so a research report would lose most of its text
before the model saw it. Extraction now keeps up to 120,000 characters (ten
windows), and a document longer than one window is summarized in parts:

1. `ArticleChunker` splits the extracted text deterministically. The extractor
   writes every `<h1>`-`<h6>` as a `## Heading` line, so a document with
   headings is cut at a heading whenever one falls in the last 40% of the
   window; a document with none falls back to fixed windows that end on a
   paragraph, sentence or word boundary. At most 10 chunks are ever produced.
2. Each chunk gets its own condensing call, which returns a short summary of
   that part only.
3. A final synthesis call receives those part summaries and produces the
   archive contract — the three-sentence summary, technical depth, topics and
   the 1-100 quality score. A condensing call never sets the score.

Every call's usage block is priced and summed, so `summary_cost_usd` and the
token columns are the article's true cost (a three-part article is four calls,
not one). The marker for how it was summarized is stored on the article as
`summary_strategy` (`single`, `headings` or `windows`) and
`summary_chunk_count`, written on create next to the other summary facts and
exposed by `GET /articles`.

Being chunked is not the same as being long form. `LongForm` adds the
**Long form** topic from the length that was extracted — 20,000 characters —
and nothing else: the tag is not in the topic list offered to the model, a copy
returned by the model is dropped, and it is appended after the subject topics.
It is seeded in `db/seed-taxonomy.cypher` under its own `Format` heading, so it
groups and filters like any other topic without ever being a model judgement.

#### Daily budget and the Neo4j breaker

Auto-pull keeps its policy state in `tmp/auto-pull.state.json`: the current day,
spend in dollars, summaries written, consecutive failures, and the instant a
cooldown expires. The file is written atomically, survives a restart, and rolls
its counters at local midnight. The sheet is meant to be read, not hand-edited:

```powershell
Get-Content tmp/auto-pull.state.json
```

A pull starts only when `AutoPull::Policy` allows it, and every skip is reported
through `GET /auto-pull` as `worker.reason` (`ok`, `budget`, `backoff`,
`config`) with `worker.retry_at`, so the dashboard can say "Paused: daily
budget reached" or "Paused: Neo4j unreachable, retrying 17:42".

- **Summary cap.** `NEWSAGG_EXPECTED_DAILY_STORIES` (default 90) is the expected
  number of new, non-archived stories summarized per day. The hard cap is twice
  that — 180 summaries by default — and `NEWSAGG_DAILY_BUDGET_USD` (default
  0.10) is the secondary hard stop in dollars. Whichever trips first wins.
  Remaining budget is checked before every story summary, so a run stops
  cleanly mid-list and the rest waits for the next day; a truncated run is not a
  failure.
- **Exact metering.** The summarizer prices DeepSeek's `usage` block
  (`prompt_tokens`, `prompt_cache_hit_tokens`, `completion_tokens`) with the
  input, output, and cache-read rates in `DeepseekSummarizer`. Cost is never
  estimated from article length.
- **Recalibrate the cap.** The default 2x90 is a starting guess. Read
  `summaries` from the state file each day, take the observed daily median, and
  set `NEWSAGG_EXPECTED_DAILY_STORIES` to that median (the cap is then 2x it).
- **Neo4j breaker.** Missing `NEO4J_PASSWORD`/`NEO4J_HTTP_URL`, HTTP 401/403, or
  an invalid Cypher statement latches the puller off (`config`) until the web
  process restarts or those env values change, so a typo cannot burn a request
  every minute. Refused connections, timeouts, 5xx responses, and Hacker News
  429/network errors back off for 60 seconds, then 5, 15, and 30 minutes
  (honoring `Retry-After` when the server sends it), then one half-open probe.
  A batch that completes with zero new stories counts as success. The breaker
  never touches `tmp/hn-retry.json`: failed stories keep waiting there and the
  file stops growing while the breaker is open.

Set `DEEPSEEK_BASE_URL` and `DEEPSEEK_MODEL` to override the provider defaults.
Use `--feed top` or `--feed best` to change the Hacker News feed, `--dry-run` to
print records without writing Neo4j or the retry file, and `--limit` to bound a
batch. The worker reads the live archive, never calls the model for URLs already
in the archive, and prints the importer-contract records on standard output.

Article fetches are limited to public HTTP(S): credentials in URLs, private or
mixed DNS answers, non-HTML bodies, HTTPS downgrades, and oversized or slow
responses are rejected. Redirects, body size, DNS resolution, and total time are
bounded. Publisher text and article prose are treated as untrusted data: tags
and control characters are stripped, model-returned topics must match the local
taxonomy, and model output can never set the article URL, publisher, or source.
Failed fetches and imports are written to the retry file with their attempt
count, and the next batch retries them without re-running a completed summary.

## Tests

The dashboard and ingestion integration tests use stubbed external services and a
disposable archive, so they never call Hacker News, DeepSeek, or a live Neo4j
database:

```powershell
bundle exec ruby test/integration/sign_in_gate_test.rb
bundle exec ruby test/integration/top_bar_test.rb
bundle exec ruby test/integration/auth_overlay_test.rb
bundle exec ruby test/integration/two_factor_sign_in_test.rb
bundle exec ruby test/integration/mfa_flow_test.rb
bundle exec ruby test/integration/asset_charset_test.rb
bundle exec ruby test/integration/dashboard_test.rb
bundle exec ruby test/integration/dashboard_pagination_test.rb
bundle exec ruby test/integration/infographic_test.rb
bundle exec ruby test/integration/ingestion_test.rb
bundle exec ruby test/integration/quality_score_test.rb
bundle exec ruby test/integration/source_score_test.rb
bundle exec ruby test/integration/long_form_test.rb
bundle exec ruby test/integration/source_registry_test.rb
bundle exec ruby test/integration/source_gate_test.rb
bundle exec ruby test/integration/rss_adapter_test.rb
bundle exec ruby test/acceptance/source_allowlist_acceptance_test.rb
bundle exec ruby test/integration/auto_pull_test.rb
bundle exec ruby test/integration/auto_pull_budget_test.rb
```

The first drives the public landing page and the sign-in gate over HTTP: a guest
reaches only `/` and the Devise screens, the data endpoints answer 401 JSON
instead of a redirect, signing in and signing up land on `/dashboard`, and a
guest sent back from a gated screen returns to it after signing in. The top-bar
test covers the account menu in both states, the Profile and Admin console links
appearing as soon as their routes exist, the single copy of the product title,
and the Devise sign-in form still submitting through the layout. The auth
overlay test covers the landing page's floating sign-in: both triggers keep an
href fallback, the embedded render inside the frame drops the top bar for a
compact card carrying the same form, and a wrong password re-renders its error
in the frame. The two-factor test covers sign-in for an account with MFA on:
the password step asks for the six-digit code instead of signing in, a valid
code finishes the sign-in, a wrong one fails in place without charging a
failed attempt or locking the account, and an account with MFA off still signs
in with one POST. The MFA flow test is the end-to-end seam between enrolment
and sign-in: an account turns MFA on through `/account` with the key the page
printed, signs in with a code generated from that key, is refused wrong codes
without a failed attempt or a lockout, turns MFA off and signs in with one POST
again, and no other account's page shows the key, the setup URI, or that MFA is
on. The asset
charset test checks that `/dashboard.css`, `/dashboard.js` and `/turbo.js`
declare UTF-8 and that the stylesheet's glyphs still reach the client as the
same UTF-8 bytes.

The next exercises Rails rendering, server-side filtering and counts, the Turbo
stream ETag, and the Auto-pull endpoint. The second runs the Ruby ingestion
pipeline against recorded Hacker News and article fixtures, a fake DeepSeek
endpoint, and a disposable in-memory archive, including retry handling and secret
redaction. The quality score test pins the 1-100 seam end to end: the prompt
carries the rubric, a stub provider returning 87 stores 87, 0 and 101 are clamped
to 1 and 100 and logged, a missing or non-numeric score falls back to the
documented default of 50 and is logged, a replayed import keeps the first score
and cost, `GET /articles` carries both fields, the card shows the score, and a
quality sort ranks mixed scored and unscored articles. The source score test pins
the source-level policy: the decayed average matches the 0.95-per-article-age
formula and follows recent output rather than the whole history, a source with
no scored articles has no score, four low articles do not pause it while the
fifth does (with the reason naming the score, the count and the threshold), an
exactly-40 score is not below the floor, `override: true` loads as a boolean,
defaults to false, refuses a non-boolean and prevents the pause, and the gate and
adapter map both stop a paused source until the pause is cleared. The
disposable-Neo4j source score test carries the same story through a real graph —
scores and counts written on the nodes, the auto-pause at the fifth article with
`paused_at`/`pause_reason`, the override keeping a 10-scoring source on, cost
still accumulating after a pause, a config re-sync not undoing it, the admin
console rendering the score and the pause reason, and `Resume` restoring fetching
without losing an article. The source registry test
loads the committed allowlist and proves
every malformed case refuses to boot — unknown or missing kind, missing or
non-http url, duplicate name, unknown key, bad types — and that an unlisted
source never appears and an empty list stays empty. The source gate test proves
the pre-fetch allowlist: an unregistered candidate, an embedded link labelled
with an unlisted source, a candidate with no source, a disabled entry and a
disallowed domain are all dropped with a recorded reason and a spy fetcher that
is never called, while a registered enabled source passes and an empty allowlist
runs a whole pass without a fetch. The RSS adapter test parses a recorded feed
into the shared candidate shape, covers guid-less items, relative links,
duplicate guids within one feed and across two polls (one article, one
discovery), a 30-item feed under a 25-item limit, and a malformed feed that is
reported as `adapter_failed` while the healthy source in the same pass still
imports. The third drives the
in-process Auto-pull supervisor with a fake ingestion runner and a short
interval: immediate pull on enable, the next tick,
stopping on disable, skipping an in-flight trigger, the `/auto-pull` payload, the
single-process pid lock, and the boot reset that clears a leftover flag before
anything pulls while leaving the policy state alone. The fourth pins the budget
and breaker behavior with an injected clock and fake runner: the summary and
dollar caps stopping a run mid-list, the local-day rollover, the `:config`
latch, the 60s → 5m → 15m → 30m backoff with a half-open probe, zero-new-story
success, exact usage pricing, and the policy state surviving a restart.

The repeat-import, source materialisation, source cost and source score suites
need a throwaway Neo4j server. The wrapper
downloads pinned Neo4j Community 5.26.0 and, when Java 21 is not available, a
pinned Temurin JRE. It starts the server on `127.0.0.1:17687` (Bolt on 17688),
runs the tests, then stops the server and deletes the temporary directory.

```powershell
pwsh -NoProfile -File ./test/support/neo4j-test.ps1
```

The test refuses to run unless `NEO4J_TEST_DISPOSABLE=1` is set, the URL is
loopback, and the HTTP port is not 7474. It never connects to an existing local
database or reads local credentials; the wrapper generates a password for the
disposable server. Add `-Keep` to inspect the `tmp/neo4j-test-*` directory after
a failure. GitHub Actions runs every test command in the required `checks` job.

The `checks` job takes about two minutes. [docs/ci-performance.md](docs/ci-performance.md)
records the per-step timings, the sharding/ubuntu options that were weighed, and
why the job is not being optimised right now.

## Hermes Kanban development

The local `newsagg` Hermes board uses the existing gateway and DeepSeek Flash.
The `newsagg` profile handles implementation and review. The `newsaggdebug`
profile is for explicit escalation. Each card gets a Git worktree based on the
selected ref and a one-shot worker with a 20-minute runtime cap.

From PowerShell in this checkout, put the expected behavior and relevant test
command in a task file, then run:

```powershell
git fetch origin main
.\bin\submit-kanban.ps1 -Title 'Fix the dashboard toggle' -TaskFile .\task.md
hermes kanban --board newsagg list
hermes kanban --board newsagg show <card-id>
```

For review, pass `-Mode review -Ref <commit-or-branch>` and identify the diff
base in the task file. Pass `-Mode debug` for a harder investigation. The
gateway dispatches queued cards. Implementers leave local commits for review,
and reviewers report findings without editing. Push and open the PR after
checking the result. GitHub still runs the required checks.

## Agent usage and cost

`bin/submit-kanban.ps1` records token usage after it creates a card, and
`bin/kanban-usage.py` reports it on demand. The reporter reads the card's
`worker_session_id` from `hermes kanban runs <card> --json`, opens the profile's
`state.db`, and sums the `session_model_usage` rows for that session into a
markdown table with a totals row, the model, and the pricing source:

```bash
python bin/kanban-usage.py <card-id>
python bin/kanban-usage.py <card-id> --markdown usage.md --json usage.json
python bin/kanban-usage.py --sweep --ledger tmp/usage/ledger.jsonl --kanban-comment
```

Usage stays on this machine. `--ledger` appends one JSON line per
`(task, session_id)` to a git-ignored JSONL file, and `--kanban-comment` stores
the table on the card in the board's own SQLite, skipping cards that already
carry an `### Agent usage` heading. `--sweep` catches up every finished card on
the board and skips cards with no worker session. GitHub receives no spend data
unless a PR comment is requested explicitly with `--comment-pr <n>`; nothing
else in the tooling touches GitHub.

Token counts are exact. The dollar column is an estimate from the provider's
pricing snapshot, so a run whose rows have `cost_status` other than `estimated`
prints a warning instead of pretending the cost is known.
