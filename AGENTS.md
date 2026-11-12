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
