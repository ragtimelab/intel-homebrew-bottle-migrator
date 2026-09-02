---
name: intel-homebrew-bottle-migrator
description: Audit and migrate any requested set of Homebrew formulae on Intel macOS without local source builds. Use for missing Intel bottles, Tier 3 or end-of-Intel ownership planning, MacPorts public-binary candidates, or official x86_64 upstream replacements; do not use for cask migration, Apple Silicon, or routine successful upgrades.
---

# Intel Homebrew Bottle Migrator

Treat the live host, package receipts, executable resolution, runtime linkage,
and current official release metadata as the source of truth. Record UTC and
local time with `date` before diagnosing or changing anything. Never treat a
past report, memory, prefix, or catalog version as current host evidence.

## Interpret the request

Derive one target set from the user's natural-language request. A target set may
contain one formula, several formulae, source-build-risk formulae, or every
installed formula. Cardinality does not select a different workflow.

Planning is read-only. Do not install, unlink, uninstall, clean, edit shell
configuration or consumer repositories, request elevation, or write agent
memory unless the user separately authorizes that mutation. Before cohort
analysis or an approved transition, read [references/runbook.md](references/runbook.md).
Read [references/schema-v2.md](references/schema-v2.md) when creating or
consuming inventory, candidate, or plan JSON.

## Evidence workflow

1. Run `scripts/collect_inventory.zsh` with repeated `--formula` selectors or
   `--all`. It captures the installed formula inventory and expands the relevant
   dependency and reverse-dependency cohort without changing package state.
2. Use `scripts/audit_formula.zsh` for detailed formula and command-path
   evidence. Do not infer ownership from a prefix alone.
3. Let the LLM select current candidates from official metadata. Validate a
   MacPorts candidate with `scripts/verify_port_closure.zsh`; validate an
   already downloaded upstream executable with
   `scripts/verify_upstream_binary.zsh`.
4. Create a schema-v2 plan containing evidence references and typed decisions,
   never shell commands. Run `scripts/validate_plan.zsh` before presenting it.
5. After explicit approval, run `scripts/preflight_apply.zsh`. Continue only
   when the approved plan digest and live ownership evidence still match.
6. Perform approved transitions one at a time under LLM supervision, using the
   state sequence and rollback rules in the runbook. Use
   `scripts/plan_orphans.zsh` only for read-only, product-scoped cleanup review.

## Hard boundaries

- Support Intel `x86_64` macOS only. Treat casks as evidence-only and leave them
  unchanged.
- MacPorts is optional during inventory collection. For a MacPorts candidate,
  use `/opt/local` and a real binary-only `port -b` install. A `port -b -y`
  plan and a manually fetched archive do not prove MacPorts signature trust.
- Never cross-link `/usr/local` and `/opt/local`, execute a downloaded archive
  during planning, use a source fallback, run `curl | sh`, or execute commands
  embedded in JSON.
- Expand shared-library targets to their installed runtime consumers. Never
  replace a shared library in isolation.
- Compare the candidate with the active runtime. Catalog lag is not itself a
  downgrade. Record package, dynamic-library, and embedded-runtime versions
  separately.
- Treat a functional difference as `adaptation_required` when an explicit,
  approved consumer change may preserve the outcome. Do not hide differences
  behind global wrappers.
- Missing critical or high fixes, active exploitation, unverifiable security
  severity, wrong architecture, incompatible ABI, required-feature loss,
  unresolved consumers, failed tests, unavailable public binary closure, and
  foreign package-manager linkage are hard blocks.
- Never combine a migration with broad `brew upgrade`, `brew autoremove`, or
  unscoped `brew cleanup`. Never retry by weakening a failed safety gate.

## Completion proof

Report requested seeds, expanded cohort, old and new owners, absolute paths,
package/shared/embedded versions, architecture, linkage prefixes, provenance,
representative tests, removed scope, cask preservation, rollback or reinstall
state, deferred or blocked scope, and exact UTC and local completion times.
Write agent memory only when the user explicitly requests it and only through
the host product's documented memory mechanism.
