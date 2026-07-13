# Contributing

Contributions are welcome. Keep the deterministic substrate model-neutral: shared behavior belongs in
`bin/`, `hooks/`, templates, or the common `skills/*/SKILL.md` tree; harness manifests should remain thin.

Before opening a pull request:

1. Create a focused branch and keep unrelated changes out.
2. Add or update a golden assertion in `tests/run.sh` for behavior changes.
3. Run `bash tests/run.sh`, `claude plugin validate .`, and `git diff --check`.
4. Validate `.codex-plugin/plugin.json` and every `skills/*/agents/openai.yaml` in a Codex environment.
5. Explain privacy, prompt-injection, concurrency, and migration implications where relevant.
6. Do not include real wiki content, source documents, credentials, customer names, or organization-specific
   paths in fixtures, screenshots, issue reports, or commits.

Bug reports should include a minimal synthetic wiki, command output, OS/shell/Python versions, and the
plugin commit. Proposals for new source connectors should follow `docs/ingestion-adapters.md`; acquisition
differences alone do not require a new semantic workflow.

By contributing, you agree that your contribution is licensed under Apache-2.0.
