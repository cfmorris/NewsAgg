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

The source pollers, automated classification, and scheduled imports are pending.
The current queries use standard Cypher.

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
