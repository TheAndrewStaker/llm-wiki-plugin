# Changelog

This project follows Keep a Changelog and intends to use Semantic Versioning after its first public release.

## [Unreleased]

### Added

- Shared Claude Code and Codex plugin/skill discovery.
- Model-neutral `wiki` CLI, deterministic lint/search, retrieval evaluation, and OKF export validation.
- Immutable source staging with SHA-256 provenance and an explicit untrusted-content policy.
- Hub-and-spoke pointer pages, configurable advisory budgets, and serialized lifecycle writes.

### Changed

- Network push is now opt-in (`auto_push: false` by default).
- The project describes working trees as OKF-aligned and exported bundles as the interchange boundary.
