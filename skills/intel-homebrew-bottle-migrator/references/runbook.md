# Binary-only migration runbook

Use this runbook for target-set cohort analysis and explicitly approved package
ownership transitions. Recheck every drift-prone fact immediately before use.

## 1. Establish the target set

Record UTC and local time with `date`, then inspect only the environment facts
needed for this host: `sw_vers`, `uname -m`, `uname -r`, package-manager
versions and prefixes, installed receipts, current and fresh-login paths,
symlink targets, declared dependencies, installed reverse dependencies, and
runtime linkage.

Run exactly one selector form:

```sh
scripts/collect_inventory.zsh --formula FORMULA [--formula FORMULA ...]
scripts/collect_inventory.zsh --all
```

The requested formulae are seeds. The collector expands them across installed
dependency and reverse-dependency edges so a shared runtime cohort is not split
accidentally. `--all` merely selects every installed formula as a seed. Casks
remain out of scope, but their formula requirements are recorded as protection
evidence.

## 2. Select and verify candidates

The LLM selects candidates from current official metadata; the skill does not
ship a formula-to-port map. Prefer a complete MacPorts public binary closure,
then an official immutable x86_64 upstream artifact, then retirement of a
verified duplicate or a dependency proven orphaned after its consumer moves.

For MacPorts, record the exact port, revision, and variants. A dry plan is only
planning evidence:

```sh
/opt/local/bin/port -b -y install PORT +VARIANT
scripts/verify_port_closure.zsh [--variant +NAME|-NAME] PORT
```

Manual archive inspection proves availability, structure, manifest identity,
architecture, and visible linkage only. It never proves MacPorts signature
trust and never authorizes package mutation. The approved real install must
retain `-b` and is the final source-fallback and signature gate.

For an official upstream candidate, obtain the artifact only from the canonical
publisher. Do not use `curl | sh`. Require an immutable version and publisher
checksum or signature, then inspect the already downloaded binary without
executing it:

```sh
scripts/verify_upstream_binary.zsh \
  --file /ABSOLUTE/PATH/TO/BINARY \
  --expected-sha256 SHA256
```

Record publisher, canonical release URL, update path, configuration retention,
and rollback method separately; the local helper cannot prove publisher
identity by itself.

Compare versions on independent axes. A candidate below the active runtime is
an ownership downgrade. A candidate below another catalog is catalog lag, not
automatically a downgrade. Verify required features and relevant security
fixes instead of using version distance as a proxy.

## 3. Build and validate the plan

The LLM writes schema-v2 JSON with one decision for every formula in the
expanded cohort. Use `deferred` or `blocked_security` when evidence is missing;
never guess or leave an `unknown` final state. Plans may contain typed
transitions and arguments, but never command strings or credentials.

```sh
scripts/validate_plan.zsh --inventory INVENTORY.json --plan PLAN.json
```

Validation is not authorization. Present feature differences, security
evidence, accepted-risk candidates, consumer adaptations, rollback state, and
the exact plan digest to the user.

## 4. Revalidate and transition

After explicit user approval, revalidate the approved plan and current host:

```sh
scripts/preflight_apply.zsh \
  --inventory INVENTORY.json \
  --plan PLAN.json \
  --plan-sha256 DIGEST
```

The preflight is read-only. On any host, ownership, cohort, candidate, or plan
drift, regenerate the evidence and plan rather than patching the old plan.

For each approved target, follow this state order:

```text
AUDITED -> CANDIDATE_PLANNED -> CANDIDATE_INSTALLED
  -> ABSOLUTE_PATH_VERIFIED -> OLD_OWNER_UNLINKED
  -> LOGIN_SHELL_VERIFIED -> OLD_OWNER_REMOVED
  -> ORPHANS_PLANNED -> ORPHANS_REMOVED -> FINAL_VERIFIED
```

1. Determine the approved elevation method. Never read or store an
   administrator password.
2. Install a MacPorts candidate with `/opt/local/bin/port -b install ...`.
   Snapshot active, requested, and unrequested ports first. A late archive
   failure may leave earlier dependencies installed; stop and review the exact
   delta without retrying without `-b`.
3. Verify the candidate by absolute path: receipt or provenance, `file`,
   `otool -L`, self-reported version and features, configuration, and a
   representative function or project test.
4. Unlink the Homebrew formula while retaining its keg. Start a fresh login
   shell and repeat resolution and functionality tests.
5. On failure, relink the old keg and stop. On success, recompute reverse
   dependencies and uninstall only the approved old owner with
   `HOMEBREW_NO_AUTOREMOVE=1`.
6. Generate a read-only orphan plan. Before every separately approved removal,
   recheck the receipt and live installed reverse dependencies. Never execute
   the JSON plan blindly.
7. Finish with fresh-login paths, functionality, architecture, same-owner
   linkage, old-owner absence, `brew missing`, and `port -b rev-upgrade` when
   MacPorts changed.

Consumer repository changes are separate mutations. Recreate virtual
environments from declared dependencies instead of retargeting them. Adapt
explicit call sites only after the user approves the repository scope.

## 5. Failure and recovery

- Before Homebrew uninstall, the retained keg is the immediate rollback.
- A user-approved complete deletion ends that rollback; report that recovery
  now requires a separately verified reinstall.
- A local archive is recovery material, not proof that the public archive is
  still downloadable.
- Preserve bounded evidence on a hard block or failed representative test.
  Do not clean, broaden scope, or weaken a safety gate.
- A temporary source build is not migrated ownership and is outside this
  skill's binary-only workflow.

## 6. Completion

Report package, shared-library, and embedded-runtime versions separately;
paths, architecture, linkage, provenance, function tests, removed scope,
preserved casks and user data, rollback state, and deferred or blocked scope.
Record exact UTC and local completion time with `date`.
