# Technical Reading Room

### Collect Hacker News candidates

With the dashboard running and Node.js 20 or later, run:

```powershell
node bin/fetch-hn.mjs --limit 10
```

The script reads the official Hacker News API and checks candidates against the live
archive by discussion ID and article URL. Use `--feed top` or `--feed best` to
change the feed, or `--archive` to point to another dashboard's articles endpoint.

Review each source and add `publisher`, a three-sentence `summary`, `depth`,
and `topics` to the candidate record. Add `published_date` when the source
verifies it. The `submitted_at` field is the Hacker News submission time.
Save the reviewed array as UTF-8 JSON and send it to the existing importer:

```powershell
Get-Content -Raw -Encoding UTF8 .\reviewed-articles.json | ruby .\bin\import-news
```

Rails serves the dashboard and reads the archive through Neo4j's HTTP Query API.
Opening `news-dashboard.html` directly shows the first digest as an offline preview.

## Run locally

Install Ruby 3.2 or newer with Bundler and the RubyInstaller MSYS2 toolchain,
start your Neo4j instance, and run these
commands from this directory in PowerShell. Set the database and user for the
archive if they differ from the defaults. The import creates constraints and
writes nodes with labels prefixed by `News`.

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
A second discovery for the same
canonical URL adds a discovery link and reuses the original summary.

Source pollers for other sites and scheduled imports are pending.
The current queries use standard Cypher.

### Automated Hacker News batch

The batch command combines the intake script with public article fetches, publisher
extraction, DeepSeek structured summaries and tags, and the existing Neo4j importer:

```powershell
$env:NEWSAGG_SUMMARY_PROVIDER = 'deepseek'
$env:DEEPSEEK_API_KEY = Read-Host 'DeepSeek API key' -MaskInput
node bin/ingest-hn.mjs --limit 10 --retry-file tmp/hn-retry.json
```

For automatic updates, run `node bin/ingest-hn.mjs --watch` in a separate
terminal with the same provider and Neo4j settings. Keep Rails and the worker
running from the same checkout. Auto-pull starts off. Turn it on beside
**Date added** to let the worker run a batch at its next 60-second check.
Turn it off to skip future batches. Any batch already running finishes.
The dashboard refreshes after articles are imported. Press Ctrl+C to stop
the worker.

Set `DEEPSEEK_BASE_URL` and `DEEPSEEK_MODEL` to override the provider defaults, and
`NEWSAGG_RUBY` if the Ruby executable is not on `PATH`. The command reads the live
archive (or `--archive -` for JSON on standard input), never calls the model for URLs
already in the archive, and prints the importer-contract records on standard output.
Use `--dry-run` to print records without writing Neo4j or the retry file.

Article fetches are limited to public HTTP(S): credentials in URLs, private or mixed
DNS answers, non-HTML bodies, HTTPS downgrades, and oversized or slow responses are
rejected. Redirects, body size, DNS resolution, and total time are bounded. Publisher
text and article prose are treated as untrusted data: tags and control characters are
stripped, model-returned topics must match the local taxonomy, and model output can
never set the article URL, publisher, or source. Failed fetches and imports are written
to the retry file with their attempt count, and the next batch retries them without
re-running a completed summary.

## Tests

The intake tests use Node's built-in test runner with recorded Hacker News
responses. They never call the live Hacker News API.

```powershell
node --test test/intake/fetch-hn.test.mjs
```

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
a failure. GitHub Actions runs both test commands in the required `checks` job.
