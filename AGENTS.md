# Testing

- For every bug fix, write a regression test that reproduces the reported behavior before changing production code. Run it and confirm it fails for the reported reason. Apply the fix, rerun the same test, and confirm it passes. Report both results in the pull request.
- For other changes, test-first development is optional. Add tests only when they cover behavior that needs protection.
- Never write tests that assert configuration or fixture data. Use fixtures to exercise application behavior.
- Keep unit tests sparse. Prefer integration tests through the CLI, HTTP routes, or database boundaries. Use a disposable database for write tests.
- Run the relevant suite before opening a pull request.

# Hermes Kanban

- Every feature request or bug fix gets a kanban card before any production code changes. The brief states the root cause for a bug, or the requested behavior for a feature, plus the mode.
- Deliver a finished card as a PR against `main` with auto-merge armed (`gh pr merge --auto --merge`) so it lands as soon as the required `checks` job passes; when GitHub reports the branch BEHIND or DIRTY, rebase it onto `main` and push with `--force-with-lease` instead of force-merging.
- Before submitting a task to Hermes Kanban, show the user the proposed scope and mode and wait for explicit approval to queue it.
- Treat exploratory questions and discussion as opportunities to refine the proposal. Approval to queue applies to the scope presented to the user.

## Where planned work lives

- Work that is planned but not yet queued lives on the `newsagg` board as a card, not as a file in `tmp/`. `hermes kanban --board newsagg create "<title>" --triage` parks an idea in `triage` for a specifier to flesh out; `create` without `--triage` lands in `ready`. Committed work that is ordered behind another card belongs in `todo`, which a dependency creates.
- Every card body carries enough scope to act on: the goal, the approach, and acceptance criteria. Never write "see tmp/task-*.md" - the card must stand on its own once the file is gone.
- `tmp/task-*.md` is only for a brief that is about to be submitted through `bin/submit-kanban.ps1`. Delete it once the card exists. Credential and config files such as `tmp/newsagg.env` stay where they are.
- Express ordering with dependencies, not prose: `hermes kanban --board newsagg link <parent-id> <child-id>` puts the child in `todo` until the parent completes, so it cannot be dispatched early. `create --parent <id>` sets the same dependency at creation time.
- Status names follow the CLI: `create` -> `ready`, `create --triage` -> `triage`, `link` -> child is `todo`, `block` -> `blocked`, `schedule` -> `scheduled`. `promote` accepts only `todo` or `blocked`; `unblock` returns `blocked` to `ready`, or to `todo` while a parent remains open.
- The board is the single source of truth. A proposed roadmap raised in chat becomes cards before the conversation moves on.

## Kanban CLI from a dispatched worker

A dispatched worker, and any delegated/deferred child it spawns, runs with the board DB **fenced**: mutating verbs exit 1 with `kanban: delegate_task child contexts cannot mutate Kanban tasks or boards`.

| verb | worker |
| --- | --- |
| `list` / `ls`, `show <id>`, `stats`, `boards list`, `diagnostics`, `assignees` | allowed — read-only |
| `list --refresh` | denied — it recomputes ready/todo gating, which is a write |
| `dispatch`, `create`, `assign`, `comment`, `edit`, `block`, `complete`, `promote`, `archive`, … | denied — human or dispatcher only |

Write card test plans in two lanes:

```sh
# human / dispatcher: advance the queue
hermes kanban dispatch --max 1

# worker: inspect the board without mutating it
hermes kanban stats
hermes kanban show <task-id>
```

Never read the board SQLite directly to work around the fence.
