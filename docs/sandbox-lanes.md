# Sandbox lanes

Cards are implemented by an agent inside a disposable Docker container, not on the
developer's machine. Each card gets its own git worktree mounted at its host path,
so absolute paths in docs, tests and scripts resolve the same way they do locally.
The container carries the language runtime, the locked dependency set and whatever
test services the card needs. It is destroyed when the card ends, so uncommitted
work is lost; a worker commits to the card branch as it goes.

## The three lanes

### `offline` (default)

The container has no network at all. This is the lane for ordinary code and test
work against the baked dependency set and the checked-in doubles, such as
`test/support/fake_archive.rb`. The contract test for that double needs no
database and no Neo4j, so it runs here:

```bash
bundle exec ruby test/integration/fake_archive_contract_test.rb
```

A card that turns out to need a download does not try to work around the missing
network; it blocks with that reason.

### `vetted`

Egress goes through an allowlist. Use it only when a card must fetch something or
change dependencies — a new gem, a lockfile bump, a pinned toolchain. Anything that
edits a dependency manifest belongs here rather than in the offline lane.

### `graph`

Adds a JVM and a disposable Neo4j to the container. Anything that touches
`app/services/archive.rb` or the Neo4j integration tests belongs in this lane:
those tests start their own server on a loopback port and refuse to run unless
`NEO4J_TEST_DISPOSABLE=1` is set.

## Commit and review

Workers commit to the card branch in small commits and then request review. They
never push. Only the reviewer lane pushes, and only after running the full suite on
the host.

## Landing a batch

Cards that pass review accumulate on the `next` integration branch. One pull
request from `next` to `main` opens per batch, so `main` moves in coherent groups
instead of one merge per card.
