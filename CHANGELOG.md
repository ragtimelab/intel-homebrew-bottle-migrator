# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses Semantic
Versioning.

## [Unreleased]

## [0.1.3] - 2026-09-03

### Fixed

- Preserved signed, immutable release tags by using `gh skill publish` for
  validation and `gh release create --verify-tag` for publication, matching the
  verified behavior of GitHub CLI 2.99.0.

## [0.1.2] - 2026-09-03

### Changed

- Added explicit MIT skill metadata and documented immutable GitHub CLI and
  skills.sh-compatible installation paths.
- Made tag immutability, warning-free publisher validation, released-tree
  installation, and skills.sh indexing checks part of the release contract.

## [0.1.1] - 2026-09-03

### Fixed

- Removed runtime reliance on executable mode bits that GitHub archive-based
  skill installation may not preserve.
- Made helper-to-helper calls invoke `/bin/zsh` explicitly and made the offline
  suite validate an archive-installed tree.

## [0.1.0] - 2026-09-03

### Added

- One target-set workflow for one, several, or all installed Homebrew formulae.
- Read-only inventory collection with dependency and reverse-dependency cohort
  expansion and digest-bound environment and ownership evidence.
- Detailed Homebrew ownership, MacPorts archive-closure, upstream artifact, and
  orphan evidence helpers.
- Schema-v2 plan validation and live apply preflight without package mutation.
- LLM-supervised migration runbook with binary-only, cask-preservation,
  no-cross-prefix, and explicit-approval boundaries.
- Offline fixture tests and SHA-pinned GitHub Actions workflows.

[Unreleased]: https://github.com/ragtimelab/intel-homebrew-bottle-migrator/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/ragtimelab/intel-homebrew-bottle-migrator/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/ragtimelab/intel-homebrew-bottle-migrator/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ragtimelab/intel-homebrew-bottle-migrator/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ragtimelab/intel-homebrew-bottle-migrator/releases/tag/v0.1.0
