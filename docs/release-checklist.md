# Public release checklist

- [ ] Choose the final package/repository name and update both manifests, marketplace metadata, docs, and tags.
- [ ] Run the full golden suite and both Claude/Codex manifest validators in clean environments.
- [ ] Install from a clean clone in Claude Code and Codex; exercise setup, ingest, query, wrap, and uninstall.
- [ ] Verify all nine skills appear in both harness catalogs and their starter prompts name the right skill.
- [ ] Run secret, organization-residue, dependency, and license scans over the complete git history.
- [ ] Review Apache-2.0, NOTICE, CONTRIBUTING, SECURITY, and private vulnerability reporting.
- [ ] Populate real synthetic retrieval eval cases and choose a documented Recall@k release threshold.
- [ ] Export a sample wiki and validate it against both `wiki-okf` and Google's current OKF reference tooling.
- [ ] Test upgrades from the preceding release without overwriting wiki-owned files or configuration.
- [ ] Pin release notes to a commit, create the signed tag, then publish marketplaces only after smoke tests pass.

Publishing is an external state change and is never part of an automated release check.
