# Contributing

Contributions are welcome when they preserve the evidence-first and binary-only security model.

## Requirements

- Keep all repository content in English.
- Do not add host-specific formula lists, user paths, package versions, memories, credentials, or migration decisions.
- Do not add source-build fallback, cross-prefix linking, arbitrary command execution, broad cleanup, or implicit package mutation.
- Add fixture coverage for observable behavior and security invariants.
- Pin every GitHub Action to a full commit SHA.
- Report vulnerabilities through private vulnerability reporting rather than a public issue.

## Pull requests

Create a focused branch, run the complete offline test suite, and explain the behavior and safety boundary changed by the pull request. Keep generated host evidence and downloaded archives out of Git. Pull requests must pass required CI, use verified signed commits, preserve linear history, and resolve all review conversations.
