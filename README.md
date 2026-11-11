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

Open [the local dashboard](http://127.0.0.1:3000/). Keep the server bound to
loopback because the dashboard has no separate user login.

The importer accepts a JSON array from standard input. Each row has a canonical
`url`, `title`, `summary`, `depth`, `publisher`, `topics` array, `source`,
`external_id`, and optional `discovery_url` and `published_date` (YYYY-MM-DD).
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
last pull time and any error beside the toggle. The setting lives in
`tmp/auto-pull.enabled`, so it survives a restart. A pid lock at
`tmp/auto-pull-worker.lock` stops a second web process on the same checkout from
pulling alongside the first.

The supervisor boots from `config.ru`, so `rails runner` and the console never
start a puller. Set `NEWSAGG_AUTO_PULL=0` to keep the web process from pulling.

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
bundle exec ruby test/integration/dashboard_test.rb
bundle exec ruby test/integration/ingestion_test.rb
bundle exec ruby test/integration/auto_pull_test.rb
```

The first exercises Rails rendering, server-side filtering and counts, the Turbo
stream ETag, and the Auto-pull endpoint. The second runs the Ruby ingestion
pipeline against recorded Hacker News and article fixtures, a fake DeepSeek
endpoint, and a disposable in-memory archive, including retry handling and secret
redaction. The third drives the in-process Auto-pull supervisor with a fake
ingestion runner and a short interval: immediate pull on enable, the next tick,
stopping on disable, skipping an in-flight trigger, the `/auto-pull` payload, and
the single-process pid lock.

The repeat-import integration test needs a throwaway Neo4j server. The wrapper
downloads pinned Neo4j Community 5.26.0 and, when Java 21 is not available, a
pinned Temurin JRE. It starts the server on `127.0.0.1:17687` (Bolt on 17688),
runs the test, then stops the server and deletes the temporary directory.

```powershell
pwsh -NoProfile -File ./test/support/neo4j-test.ps1
```

The test refuses to run unless `NEO4J_TEST_DISPOSABLE=1` is set, the URL is
loopback, and the HTTP port is not 7474. It never connects to an existing local
database or reads local credentials; the wrapper generates a password for the
disposable server. Add `-Keep` to inspect the `tmp/neo4j-test-*` directory after
a failure. GitHub Actions runs all three test commands in the required `checks`
job.
