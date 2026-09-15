# Changelog

This project follows Keep a Changelog and intends to use Semantic Versioning after its first public release.

## [Unreleased]

### Added

- Shared Claude Code and Codex plugin/skill discovery.
- Model-neutral `wiki` CLI, deterministic lint/search, retrieval evaluation, and OKF export validation.
- Immutable source staging with SHA-256 provenance and an explicit untrusted-content policy.
- Hub-and-spoke pointer pages, configurable advisory budgets, and serialized lifecycle writes.
- `meeting-notes` companion sources: extract text and screenshots from a note app entry or an
  exported HTML note captured alongside a transcript, keeping each image marker where it sat in the
  text and writing a readable downscaled copy (`skills/meeting-notes/scripts/extract-companion.py`).

### Changed

- `wanted-pages` honors `wanted_exempt_dirs`. A dated log entry records what happened; it is not
  where the wiki declares a page worth writing, so `[[...]]` there is prose syntax, not a marker.
- Network push is now opt-in (`auto_push: false` by default).
- The project describes working trees as OKF-aligned and exported bundles as the interchange boundary.
