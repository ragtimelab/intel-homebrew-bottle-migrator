# Repository instructions

- Treat live host evidence and official package metadata as the source of truth.
- Do not hard-code a user's paths, installed package set, operating-system build,
  package versions, credentials, or migration decisions.
- Keep repository content in English.
- Keep deterministic helpers read-only. Package-state changes remain explicit,
  user-approved, LLM-supervised transitions described by the runbook.
- Preserve the Intel x86_64, binary-only, cask-preservation, no-cross-prefix,
  no-source-fallback, and no-memory-write boundaries.
- Use `date` whenever recording or updating time.
- Use `apply_patch` for manual file edits. Preserve unrelated work.
- Run the offline test suite and the skill validator before reporting completion.
- Pin GitHub Actions to full commit SHAs and never add `pull_request_target` or
  public-repository self-hosted runners.
