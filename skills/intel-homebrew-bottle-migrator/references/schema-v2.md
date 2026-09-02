# Evidence and plan schema v2

All deterministic helpers emit one JSON document on standard output and put
bounded diagnostics on standard error. Collection and validation helpers do
not change package state.

## Inventory evidence

`collect_inventory.zsh` emits:

- `schema_version: 2`
- `recorded_at.utc` and `recorded_at.local`, both produced by `date`
- `host`: current macOS product, build, kernel, and architecture
- `managers`: Homebrew and optional MacPorts path, prefix, and version
- `scope`: selector, requested seeds, missing seeds, requested casks, and the
  expanded installed formula cohort
- `formulae`: normalized installed Homebrew formula receipts
- `casks`: token and formula-requirement evidence only
- `digests.environment`, `digests.ownership`, and `digests.evidence`
- `hard_blocks`, `warnings`, and `mutations_performed:false`

The ownership digest covers installed formula ownership and cask formula
requirements, not unrelated cask application versions.

## Candidate evidence

MacPorts evidence separates:

- public archive availability
- archive structure and manifest identity
- architecture and visible linkage inspection
- signature-file presence
- `macports_signature_verified:false`
- `requires_port_b_install:true`

Only a real approved `port -b install` performs the MacPorts trust gate.

Upstream binary evidence requires an absolute, non-symlink regular file and an
expected SHA-256. It records size, digest match, `file`, architectures,
codesign, Gatekeeper, dynamic linkage, foreign package-manager links, and
`binary_executed:false`. Publisher provenance remains separate LLM evidence.

## Migration plan

A plan is LLM-authored data with:

```json
{
  "schema_version": 2,
  "inventory_evidence_digest": "...",
  "environment_digest": "...",
  "ownership_digest": "...",
  "decisions": [],
  "transitions": [],
  "plan_digest": "..."
}
```

There must be exactly one final decision for every formula in the inventory
cohort. Allowed dispositions are:

- `macports_binary`
- `official_upstream_binary`
- `retire_duplicate`
- `retire_orphan`
- `adaptation_required`
- `deferred`
- `blocked_security`

Allowed typed transitions are:

- `install_macports_binary`
- `install_official_upstream_binary`
- `adapt_consumer`
- `verify_candidate`
- `unlink_homebrew`
- `verify_fresh_login`
- `uninstall_homebrew`
- `retire_orphan`
- `final_verify`

Each transition contains structured arguments, evidence references, rollback,
and required checks. No key named `command`, `shell`, `script`, `password`,
`token`, `secret`, or `authorization` is allowed anywhere in a plan.

The plan digest is SHA-256 of canonical compact sorted JSON after deleting the
top-level `plan_digest` field. Plan validation does not authorize execution.

## Apply preflight

`preflight_apply.zsh` validates the supplied plan digest, runs plan validation,
recollects the same selector, and compares environment, ownership, evidence,
and cohort values. It emits `authorized_by_evidence:true` only when all checks
match. This means the evidence is current; explicit user approval remains a
separate conversational requirement.
