# Workflow And Safety

- recent commit history uses short, imperative-style subjects; include issue references when they help.
- PRs should explain the behavior change, mention Bamboo or Gmail integration impact, and include tests.
- update `README.md` and `AGENTS.md` when setup, commands, or contributor workflow changes.
- when fixing an item tracked in `TODO.txt`, update that entry's status and details before finishing.
- never commit service-account JSON, impersonated `sub` addresses, or other Gmail credentials.
- follow the README pattern for secrets, such as `{:system, "GCP_CREDENTIALS"}` or loading credentials from a local file outside version control.
