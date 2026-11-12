#!/usr/bin/env bash
# Disposable Neo4j 5.26 for the Neo4j-backed tests — Linux port of neo4j-test.ps1.
#
# Downloads (once, cached, checksum-verified) the unix distribution into
# tmp/neo4j-cache, unpacks a throwaway server into tmp/neo4j-test-<id> bound to
# loopback on 17687/17688, exports NEO4J_* + NEO4J_TEST_DISPOSABLE=1, runs the
# Neo4j-backed tests against it, then tears the server down.
#
# Usage:
#   test/support/neo4j-test.sh                 # default test list
#   test/support/neo4j-test.sh --keep          # leave tmp/neo4j-test-* for inspection
#   test/support/neo4j-test.sh --tests test/integration/repeat_import_test.rb
#
# Java: JAVA_HOME, else java on PATH, else a mise-installed JDK
# (`mise install java@temurin-21.0.13+9.0.LTS`).
set -euo pipefail

KEEP=0
TESTS=(
  test/integration/repeat_import_test.rb
  test/integration/source_materialisation_test.rb
  test/integration/source_cost_test.rb
  test/integration/source_score_neo4j_test.rb
  test/acceptance/source_registry_roundtrip_acceptance_test.rb
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep|-Keep) KEEP=1; shift ;;
    --tests)
      shift; TESTS=()
      while [[ $# -gt 0 && "$1" != -* ]]; do TESTS+=("$1"); shift; done ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# NEO4J_CACHE_DIR / NEO4J_TARBALL_SHA256 let a sandbox image supply a pre-fetched
# archive — including a trimmed one with the browser UI removed — so the graph
# tests run with no network. Defaults keep host behaviour unchanged.
CACHE_DIR="${NEO4J_CACHE_DIR:-$REPO_ROOT/tmp/neo4j-cache}"
RUN_DIR="$REPO_ROOT/tmp/neo4j-test-$(date +%s)-$RANDOM"
HTTP_PORT=17687
BOLT_PORT=17688

NEO4J_VERSION=5.26.0
NEO4J_TARBALL="neo4j-community-${NEO4J_VERSION}-unix.tar.gz"
NEO4J_URL="https://dist.neo4j.org/${NEO4J_TARBALL}"
NEO4J_SHA256="${NEO4J_TARBALL_SHA256:-ad8ac3398606145502b8f489530bbd39333707ae4668156af16b6086b5b037d7}"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

fetch_cached() { # url dest sha256
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]]; then
    if printf '%s  %s\n' "$sha" "$dest" | sha256sum -c --status - 2>/dev/null; then return 0; fi
    log "Cached archive failed its checksum, re-downloading: $dest"
    rm -f -- "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  log "Downloading $url"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest.partial" "$url" \
    || { rm -f -- "$dest.partial"; die "no cached archive at $dest and the download failed — offline lane? set NEO4J_CACHE_DIR to a directory holding $NEO4J_TARBALL"; }
  if ! printf '%s  %s\n' "$sha" "$dest.partial" | sha256sum -c --status - 2>/dev/null; then
    rm -f -- "$dest.partial"
    die "Checksum mismatch for $url"
  fi
  mv -f -- "$dest.partial" "$dest"
}

resolve_java_home() {
  local candidate
  for candidate in "${JAVA_HOME:-}" "$(dirname "$(dirname "$(command -v java 2>/dev/null || true)")" 2>/dev/null)"; do
    if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  if command -v mise >/dev/null 2>&1; then
    local java_bin
    java_bin="$(mise which java 2>/dev/null || true)"
    if [[ -n "$java_bin" && -x "$java_bin" ]]; then
      printf '%s\n' "$(cd "$(dirname "$java_bin")/.." && pwd)"; return 0
    fi
  fi
  return 1
}

NEO4J_HOME=""
SERVER_PID=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$NEO4J_HOME" ]]; then
    pkill -f "$NEO4J_HOME" 2>/dev/null || true
  fi
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ $KEEP -eq 1 ]]; then
    log "Kept disposable Neo4j directory: $RUN_DIR"
  else
    case "$RUN_DIR" in
      "$REPO_ROOT/tmp/"*) rm -rf -- "$RUN_DIR" ;;
      *) log "refusing to remove unexpected path: $RUN_DIR" ;;
    esac
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

mkdir -p "$CACHE_DIR" "$RUN_DIR"
fetch_cached "$NEO4J_URL" "$CACHE_DIR/$NEO4J_TARBALL" "$NEO4J_SHA256"

java_home="$(resolve_java_home)" || die "no Java found — run: mise install java@temurin-21.0.13+9.0.LTS"
export JAVA_HOME="$java_home"
export PATH="$JAVA_HOME/bin:$PATH"
log "Java: $JAVA_HOME ($(java -version 2>&1 | head -1))"

# A mise-managed Ruby must win over a system ruby on PATH: `bundle` and `ruby`
# have to come from the same prefix or bundler loads gems under the wrong
# interpreter (Bundler::GemNotFound).
if command -v mise >/dev/null 2>&1; then
  if ruby_bin="$(mise which ruby 2>/dev/null)" && [[ -n "$ruby_bin" && -x "$ruby_bin" ]]; then
    export PATH="$(dirname "$ruby_bin"):$PATH"
  fi
fi
log "Ruby: $(command -v ruby) ($(ruby -v 2>&1 | head -1))"

tar -xzf "$CACHE_DIR/$NEO4J_TARBALL" -C "$RUN_DIR"
NEO4J_HOME="$RUN_DIR/neo4j-community-$NEO4J_VERSION"
[[ -x "$NEO4J_HOME/bin/neo4j" ]] || die "Neo4j distribution did not extract as expected"

cat > "$NEO4J_HOME/conf/neo4j.conf" <<CONF
server.default_listen_address=127.0.0.1
server.http.listen_address=127.0.0.1:$HTTP_PORT
server.https.enabled=false
server.bolt.listen_address=127.0.0.1:$BOLT_PORT
server.memory.heap.initial_size=512m
server.memory.heap.max_size=1g
server.memory.pagecache.size=256m
dbms.usage_report.enabled=false
CONF

PASSWORD="$(openssl rand -hex 16)"
"$NEO4J_HOME/bin/neo4j-admin" dbms set-initial-password "$PASSWORD" >/dev/null 2>&1 \
  || die "could not set the disposable Neo4j password"

if ss -ltn 2>/dev/null | grep -qE ":($HTTP_PORT|$BOLT_PORT)\b"; then
  die "a disposable Neo4j port is already in use ($HTTP_PORT/$BOLT_PORT)"
fi

log "Starting disposable Neo4j on 127.0.0.1:$HTTP_PORT"
"$NEO4J_HOME/bin/neo4j" console >"$RUN_DIR/stdout.log" 2>"$RUN_DIR/stderr.log" &
SERVER_PID=$!

ready=0
for _ in $(seq 1 90); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    tail -20 "$RUN_DIR/stderr.log" >&2 || true
    die "disposable Neo4j exited before it became ready"
  fi
  code="$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/" || true)"
  if [[ "$code" == "200" || "$code" == "401" ]]; then ready=1; break; fi
  sleep 2
done
[[ $ready -eq 1 ]] || die "Neo4j did not become ready on 127.0.0.1:$HTTP_PORT"

export NEO4J_HTTP_URL="http://127.0.0.1:$HTTP_PORT"
export NEO4J_USER="neo4j"
export NEO4J_PASSWORD="$PASSWORD"
export NEO4J_DATABASE="neo4j"
export NEO4J_TEST_DISPOSABLE="1"

cd "$REPO_ROOT"
rc=0
for test in "${TESTS[@]}"; do
  log "Running $test against the disposable Neo4j"
  bundle exec ruby "$test" || rc=$?
done
exit "$rc"
