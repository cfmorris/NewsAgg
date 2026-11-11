# Testing

- For every bug fix, write a regression test that reproduces the reported behavior before changing production code. Run it and confirm it fails for the reported reason. Apply the fix, rerun the same test, and confirm it passes. Report both results in the pull request.
- For other changes, test-first development is optional. Add tests only when they cover behavior that needs protection.
- Never write tests that assert configuration or fixture data. Use fixtures to exercise application behavior.
- Keep unit tests sparse. Prefer integration tests through the CLI, HTTP routes, or database boundaries. Use a disposable database for write tests.
- Run the relevant suite before opening a pull request.
