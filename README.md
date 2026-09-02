# Intel Homebrew Bottle Migrator

An Agent Skill for evidence-led, binary-only migration of Homebrew formulae on Intel macOS. It helps an LLM inspect the local host, resolve the real runtime cohort, verify MacPorts or official upstream x86_64 candidates, and carry out only explicitly approved ownership changes without falling back to local source builds.

## Why this exists

Homebrew support and bottle availability on Intel macOS can vary by formula and operating-system release. A missing bottle is not enough evidence to replace a package manager, and a candidate package is not safe merely because it exists. This skill separates live ownership, dependency and linkage evidence, binary availability, feature compatibility, security exposure, user approval, and final state verification.

## Safety model

- Audits, inventory collection, candidate verification, plan validation, and apply preflight are read-only.
- The helpers never run `sudo`, install or remove packages, edit shell startup files, write agent memory, or execute commands embedded in JSON.
- MacPorts candidates require a complete public binary archive closure and a real approved `port -b install`; source fallback is forbidden.
- `/usr/local` and `/opt/local` are never cross-linked.
- Homebrew casks are evidence-only and never changed by this skill.
- A package mutation requires explicit user approval, immediate live-state revalidation, and LLM-supervised execution one transition at a time.
- Critical or high security regressions, active exploitation, unknown security severity, wrong architecture, incompatible ABI, required-feature loss, or unverifiable provenance are hard blocks.

## Supported environment

- Intel `x86_64` macOS
- Homebrew formula ownership analysis
- Optional MacPorts candidates at `/opt/local`
- Official immutable x86_64 upstream artifacts when a managed binary candidate is unsuitable

Apple Silicon, Homebrew cask migration, routine successful upgrades, source builds, private package archives, and cross-prefix shims are out of scope.

## Installation

For an immutable, signed release, use GitHub CLI and pin the release tag:

```sh
gh skill install \
  ragtimelab/intel-homebrew-bottle-migrator \
  intel-homebrew-bottle-migrator \
  --pin v0.1.3 \
  --agent codex \
  --scope user
```

For skills.sh-compatible installation and update discovery, use the Skills CLI:

```sh
npx skills add \
  ragtimelab/intel-homebrew-bottle-migrator \
  --skill intel-homebrew-bottle-migrator \
  --agent codex \
  --global \
  --yes
```

The Skills CLI command follows the protected default branch and is convenient
for ecosystem discovery, but it is not equivalent to an immutable release pin.
Use `gh skill install --pin` when reproducibility is required. Helpers are
invoked with `/bin/zsh` and do not rely on archive installers preserving
executable mode bits.

## Natural-language examples

```text
Use $intel-homebrew-bottle-migrator to determine whether gh can leave Homebrew without any local source build.

Use $intel-homebrew-bottle-migrator to audit these formulae as one migration target set: imagemagick, libheif, and x265.

Use $intel-homebrew-bottle-migrator to inventory every installed Homebrew formula, identify all binary-only migration candidates, and present a plan without changing anything.

Apply only the reviewed migration plan from this session, stopping on any inventory drift or failed representative test.
```

The user does not select a single or bulk mode. The LLM derives an arbitrary-size target set from the request, expands the runtime cohort, and uses the same pipeline for every cardinality.

## Runtime prerequisites

The skill checks prerequisites before use and does not install them automatically. Its deterministic helpers use zsh, jq, curl, tar, file, otool, shasum, and the Homebrew CLI. MacPorts is optional for inventory collection and required only for a MacPorts candidate.

## Development

Run the offline fixture suite from the repository root:

```sh
zsh skills/intel-homebrew-bottle-migrator/tests/run.zsh
```

The pull-request suite performs no package-manager mutation, administrator authentication, or live archive download. See `CONTRIBUTING.md` and `SECURITY.md` before proposing a change.

## License

MIT
