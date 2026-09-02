#!/bin/zsh

set -eu
setopt pipefail

typeset tests_dir="${0:A:h}"
typeset skill_dir="${tests_dir:h}"
typeset fixture_root="$tests_dir/fixtures"
typeset fixture_bin="$fixture_root/bin"
typeset temp_dir
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ihbm-tests.XXXXXX")"
cleanup() { [[ -d "$temp_dir" ]] && rm -rf -- "$temp_dir"; }
trap cleanup EXIT INT TERM

# GitHub archive downloads do not reliably retain executable mode bits. The
# suite must prove that a freshly downloaded skill can recover its test-only
# fixture executability and invoke runtime helpers through their zsh shebangs.
/bin/chmod 0755 "$skill_dir"/scripts/*.zsh
/usr/bin/find "$fixture_root" -type f -exec /bin/chmod 0755 {} +

export PATH="$fixture_bin:$PATH"
export IHBM_TEST_MODE=1
export IHBM_FIXTURE_ROOT="$fixture_root"
export IHBM_LOGIN_SHELL="$fixture_bin/login-zsh"
export IHBM_MACPORTS_PREFIX="$fixture_root/opt/local"
export IHBM_CALL_LOG="$temp_dir/calls.log"

typeset -i assertions=0
fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

assert_jq() {
  local json="$1"
  local expression="$2"
  local label="$3"
  print -rn -- "$json" | jq -e "$expression" >/dev/null || fail "$label"
  assertions=$((assertions + 1))
}

assert_log_absent() {
  local pattern="$1"
  local label="$2"
  if grep -E -q -- "$pattern" "$IHBM_CALL_LOG"; then
    fail "$label"
  fi
  assertions=$((assertions + 1))
}

: > "$IHBM_CALL_LOG"
typeset audit_json
audit_json="$($skill_dir/scripts/audit_formula.zsh --port ripgrep --variant +pcre --command rg ripgrep)"
assert_jq "$audit_json" '.schema_version == 4' 'audit schema version'
assert_jq "$audit_json" '.homebrew.formula.upgrade_plan.state == "not_applicable"' 'absent formula skips upgrade plan'
assert_jq "$audit_json" '.macports.candidate.active == true and .macports.candidate.requested_variants == ["+pcre"]' 'active port and variant'
assert_jq "$audit_json" '.macports.candidate.binary_only_plan.state == "not_applicable" and .macports.candidate.remote_archive_verified == false' 'active candidate does not fake archive proof'
assert_jq "$audit_json" '.commands[0].current_shell_path | endswith("/fixtures/bin/rg")' 'current shell path is separate'
assert_jq "$audit_json" '.commands[0].fresh_login_shell_path | endswith("/fixtures/opt/local/bin/rg")' 'fresh login path is separate'
assert_jq "$audit_json" '.commands[0].candidate_binaries[0].self_reported_version.stdout | contains("PCRE2 10.45")' 'embedded version is preserved'
assert_jq "$audit_json" '.version_relation.candidate_vs_active == "equal" and .version_relation.catalog_lag_detected == true and .version_relation.ownership_transition_is_downgrade == false' 'catalog lag is separate from ownership downgrade'
assert_jq "$audit_json" '.hard_blocks == [] and .errors == []' 'clean audit has no errors'
assert_log_absent '^port -b -y install' 'active candidate attempted a port install plan'
assert_log_absent '^brew upgrade' 'absent formula attempted a brew upgrade plan'

typeset gh_json
gh_json="$($skill_dir/scripts/audit_formula.zsh --port gh --command gh gh)"
assert_jq "$gh_json" '.version_relation.active_baseline.owner == "homebrew" and .version_relation.active_baseline.version == "2.98.0"' 'linked Homebrew keg is the active baseline'
assert_jq "$gh_json" '.version_relation.candidate_vs_active == "equal" and .version_relation.candidate_vs_homebrew_catalog == "lower"' 'equal owner transition can trail the catalog'
assert_jq "$gh_json" '.version_relation.ownership_transition_is_downgrade == false and .version_relation.security_review_required == false' 'equal transition does not trigger security review'

typeset imagemagick_json
imagemagick_json="$($skill_dir/scripts/audit_formula.zsh --port ImageMagick7 --variant +openexr --variant +x11 --command-path magick=lib/ImageMagick7/bin/magick imagemagick)"
assert_jq "$imagemagick_json" '.version_relation.candidate_vs_active == "equal" and .commands[0].candidate_relative_path == "lib/ImageMagick7/bin/magick"' 'equal hyphen version and nested command path'
assert_jq "$imagemagick_json" '.commands[0].candidate_binaries[0].path | endswith("/opt/local/lib/ImageMagick7/bin/magick")' 'nested candidate binary is audited'

export IHBM_PORT_VERSION=2.97.0
gh_json="$($skill_dir/scripts/audit_formula.zsh --port gh --command gh gh)"
assert_jq "$gh_json" '.version_relation.candidate_vs_active == "lower" and .version_relation.ownership_transition_is_downgrade == true and .version_relation.security_review_required == true' 'actual active-version downgrade triggers review'
unset IHBM_PORT_VERSION

export IHBM_GH_ABSENT=1 IHBM_PORT_INACTIVE=1
gh_json="$($skill_dir/scripts/audit_formula.zsh --port gh --command gh gh)"
assert_jq "$gh_json" '.version_relation.active_baseline.version == null and .version_relation.candidate_vs_active == "unknown"' 'uninstalled catalog version is never an active baseline'
unset IHBM_GH_ABSENT IHBM_PORT_INACTIVE

export IHBM_GH_ABSENT=1 IHBM_LOGIN_OWNER=macports
gh_json="$($skill_dir/scripts/audit_formula.zsh --port gh --command gh gh)"
assert_jq "$gh_json" '.version_relation.active_baseline.owner == "macports" and .version_relation.active_baseline.version == "2.98.0"' 'active MacPorts receipt becomes the post-migration baseline'
unset IHBM_GH_ABSENT IHBM_LOGIN_OWNER

export IHBM_GH_ABSENT=1 IHBM_LOGIN_OWNER=macports
gh_json="$(PATH="$fixture_root/usr/local/bin:$PATH" $skill_dir/scripts/audit_formula.zsh --port gh --command gh gh)"
assert_jq "$gh_json" '[.hard_blocks[].code] | index("ownership_baseline_ambiguous") != null' 'current and fresh-login owner mismatch is a hard block'
unset IHBM_GH_ABSENT IHBM_LOGIN_OWNER

typeset multi_command_json
multi_command_json="$($skill_dir/scripts/audit_formula.zsh --port ripgrep --variant +pcre --command rg --command missing ripgrep)"
assert_jq "$multi_command_json" '.commands | length == 2' 'multiple command audits remain pure JSON'

export IHBM_CROSS_PREFIX=1
audit_json="$($skill_dir/scripts/audit_formula.zsh --port ripgrep --variant +pcre --command rg ripgrep)"
assert_jq "$audit_json" '[.hard_blocks[].code] | index("cross_prefix_linkage") != null' 'cross-prefix linkage is a hard block'
unset IHBM_CROSS_PREFIX

export IHBM_FAIL_USES=1
audit_json="$($skill_dir/scripts/audit_formula.zsh --port ripgrep --variant +pcre --command rg ripgrep)"
assert_jq "$audit_json" '[.errors[].stage] | index("brew_uses_direct") != null and index("brew_uses_recursive") != null' 'provider failures remain structured'
unset IHBM_FAIL_USES

set +e
typeset cask_json
cask_json="$($skill_dir/scripts/audit_formula.zsh casktool)"
typeset cask_exit=$?
set -e
[[ "$cask_exit" == 4 ]] || fail 'cask did not exit 4'
assert_jq "$cask_json" '.exit_code == 4 and (.error | contains("cask"))' 'cask result is structured'

: > "$IHBM_CALL_LOG"
export IHBM_PORT_INACTIVE=1
export IHBM_LARGE_PLAN=1
audit_json="$($skill_dir/scripts/audit_formula.zsh --port ripgrep --variant +pcre ripgrep)"
assert_jq "$audit_json" '.macports.candidate.active == false' 'inactive candidate is reported'
assert_jq "$audit_json" '.macports.candidate.binary_only_plan.state == "completed" and .macports.candidate.binary_only_plan.truncated == true' 'large plan is truncated structurally'
assert_jq "$audit_json" '(.macports.candidate.binary_only_plan.stdout | length) == 32768' 'capture limit is 32 KiB'
grep -q '^port -b -y install ripgrep +pcre$' "$IHBM_CALL_LOG" || fail 'binary-only dry plan was not invoked correctly'
assertions=$((assertions + 1))
unset IHBM_PORT_INACTIVE IHBM_LARGE_PLAN

typeset archive_root="$temp_dir/archive-source"
typeset archive_dir="$temp_dir/archives/gh"
typeset darwin_major="$(uname -r | cut -d. -f1)"
typeset archive_name="gh-2.98.0_0.darwin_${darwin_major}.x86_64.tbz2"
mkdir -p "$archive_root/opt/local/bin" "$archive_dir"
cp "$fixture_root/opt/local/bin/gh" "$archive_root/opt/local/bin/gh"
print -r -- '@name gh-2.98.0_0' > "$archive_root/+CONTENTS"
print -r -- '@portname gh' >> "$archive_root/+CONTENTS"
print -r -- '@portversion 2.98.0' >> "$archive_root/+CONTENTS"
print -r -- '@portrevision 0' >> "$archive_root/+CONTENTS"
print -r -- '@archs x86_64' >> "$archive_root/+CONTENTS"
print -r -- '@os.version 24.6.0' >> "$archive_root/+CONTENTS"
(cd "$archive_root" && tar -cjf "$archive_dir/$archive_name" +CONTENTS opt/local/bin/gh)
print -r -- 'fixture signature' > "$archive_dir/$archive_name.rmd160"
print -r -- "$archive_name" > "$temp_dir/archive-index.html"
export IHBM_ARCHIVE_BASE_URL="file://$temp_dir/archives"
export IHBM_ARCHIVE_INDEX_FILE="$temp_dir/archive-index.html"
typeset archive_json
archive_json="$($skill_dir/scripts/verify_port_archive.zsh --command gh gh)"
assert_jq "$archive_json" '.schema_version == 2 and .archive_structure_verified == true and .archive.signature_present == true and .macports_signature_verified == false and .mutations_performed == false' 'remote archive full-fetch contract'
assert_jq "$archive_json" '.archive.manifest.port == "gh" and .archive.manifest.version == "2.98.0" and .archive.manifest.architecture == "x86_64"' 'remote archive manifest identity'
assert_jq "$archive_json" '.commands[0].cross_prefix_links == [] and .hard_blocks == [] and .errors == []' 'remote archive architecture and linkage'

: > "$temp_dir/archive-index-empty.html"
export IHBM_ARCHIVE_INDEX_FILE="$temp_dir/archive-index-empty.html"
archive_json="$($skill_dir/scripts/verify_port_archive.zsh --command gh gh)"
assert_jq "$archive_json" '.archive_structure_verified == false and ([.hard_blocks[].code] | index("remote_archive_unavailable") != null)' 'missing remote archive is a hard block'
unset IHBM_ARCHIVE_BASE_URL IHBM_ARCHIVE_INDEX_FILE

typeset noarch_root="$temp_dir/noarch-source"
typeset noarch_dir="$temp_dir/archives/noarch"
typeset noarch_name='noarch-1.0.0_0.any_any.noarch.tbz2'
mkdir -p "$noarch_root" "$noarch_dir"
print -r -- '@name noarch-1.0.0_0' > "$noarch_root/+CONTENTS"
print -r -- '@portname noarch' >> "$noarch_root/+CONTENTS"
print -r -- '@portversion 1.0.0' >> "$noarch_root/+CONTENTS"
print -r -- '@portrevision 0' >> "$noarch_root/+CONTENTS"
print -r -- '@archs noarch' >> "$noarch_root/+CONTENTS"
print -r -- '@os.version 24.6.0' >> "$noarch_root/+CONTENTS"
(cd "$noarch_root" && tar -cjf "$noarch_dir/$noarch_name" +CONTENTS)
print -r -- 'fixture signature' > "$noarch_dir/$noarch_name.rmd160"
print -r -- "$noarch_name" > "$temp_dir/noarch-index.html"
export IHBM_ARCHIVE_BASE_URL="file://$temp_dir/archives"
export IHBM_ARCHIVE_INDEX_FILE="$temp_dir/noarch-index.html"
archive_json="$($skill_dir/scripts/verify_port_archive.zsh noarch)"
assert_jq "$archive_json" '.archive_structure_verified == true and .archive.manifest.architecture == "noarch"' 'any-any noarch archive compatibility'
unset IHBM_ARCHIVE_INDEX_FILE

print -r -- "$archive_name" > "$temp_dir/closure-index.html"
print -r -- "$noarch_name" >> "$temp_dir/closure-index.html"
export IHBM_ARCHIVE_INDEX_FILE="$temp_dir/closure-index.html"
export IHBM_CLOSURE_PLAN=1 IHBM_PORT_INACTIVE=1
typeset closure_json
closure_json="$($skill_dir/scripts/verify_port_closure.zsh gh)"
assert_jq "$closure_json" '.schema_version == 3 and .all_remote_archives_verified == true and (.closure_ports | sort) == ["gh","noarch"] and .mutations_performed == false' 'closure archive verification contract'
assert_jq "$closure_json" '(.effective_variants | map({key:.name,value:.selected}) | from_entries) == {gh:[],noarch:[]}' 'closure records effective variants'
unset IHBM_ARCHIVE_BASE_URL IHBM_ARCHIVE_INDEX_FILE IHBM_CLOSURE_PLAN IHBM_PORT_INACTIVE

typeset imagemagick_closure_root="$temp_dir/imagemagick-closure-source"
typeset imagemagick_closure_dir="$temp_dir/archives/ImageMagick7"
typeset imagemagick_closure_name="ImageMagick7-7.1.2-30_0+openexr+x11.darwin_${darwin_major}.x86_64.tbz2"
mkdir -p "$imagemagick_closure_root" "$imagemagick_closure_dir"
print -r -- '@name ImageMagick7-7.1.2-30_0+openexr+x11' > "$imagemagick_closure_root/+CONTENTS"
print -r -- '@portname ImageMagick7' >> "$imagemagick_closure_root/+CONTENTS"
print -r -- '@portversion 7.1.2-30' >> "$imagemagick_closure_root/+CONTENTS"
print -r -- '@portrevision 0' >> "$imagemagick_closure_root/+CONTENTS"
print -r -- '@archs x86_64' >> "$imagemagick_closure_root/+CONTENTS"
print -r -- '@os.version 24.6.0' >> "$imagemagick_closure_root/+CONTENTS"
print -r -- '@portvariant +openexr' >> "$imagemagick_closure_root/+CONTENTS"
print -r -- '@portvariant +x11' >> "$imagemagick_closure_root/+CONTENTS"
(cd "$imagemagick_closure_root" && tar -cjf "$imagemagick_closure_dir/$imagemagick_closure_name" +CONTENTS)
print -r -- 'fixture signature' > "$imagemagick_closure_dir/$imagemagick_closure_name.rmd160"

typeset giflib_closure_root="$temp_dir/giflib-closure-source"
typeset giflib_closure_dir="$temp_dir/archives/giflib"
typeset giflib_plain_name="giflib-4.2.3_1.darwin_${darwin_major}.x86_64.tbz2"
typeset giflib_x11_name="giflib-4.2.3_1+x11.darwin_${darwin_major}.x86_64.tbz2"
mkdir -p "$giflib_closure_root" "$giflib_closure_dir"
print -r -- '@name giflib-4.2.3_1' > "$giflib_closure_root/+CONTENTS"
print -r -- '@portname giflib' >> "$giflib_closure_root/+CONTENTS"
print -r -- '@portversion 4.2.3' >> "$giflib_closure_root/+CONTENTS"
print -r -- '@portrevision 1' >> "$giflib_closure_root/+CONTENTS"
print -r -- '@archs x86_64' >> "$giflib_closure_root/+CONTENTS"
print -r -- '@os.version 24.6.0' >> "$giflib_closure_root/+CONTENTS"
(cd "$giflib_closure_root" && tar -cjf "$giflib_closure_dir/$giflib_plain_name" +CONTENTS)
print -r -- 'fixture signature' > "$giflib_closure_dir/$giflib_plain_name.rmd160"

print -r -- "$imagemagick_closure_name" > "$temp_dir/closure-propagated-index.html"
print -r -- "$giflib_plain_name" >> "$temp_dir/closure-propagated-index.html"
export IHBM_ARCHIVE_BASE_URL="file://$temp_dir/archives"
export IHBM_ARCHIVE_INDEX_FILE="$temp_dir/closure-propagated-index.html"
export IHBM_CLOSURE_PLAN=propagated IHBM_PORT_INACTIVE=1
closure_json="$($skill_dir/scripts/verify_port_closure.zsh ImageMagick7)"
assert_jq "$closure_json" '.all_remote_archives_verified == true and .hard_blocks == [] and .errors == []' 'root defaults use dependency defaults without propagation'
assert_jq "$closure_json" '(.effective_variants[] | select(.name == "ImageMagick7") | .selected) == ["+openexr","+x11"]' 'root default variants select the root archive'
assert_jq "$closure_json" '(.effective_variants[] | select(.name == "giflib")) | .defaults == [] and .propagated == [] and .selected == []' 'root defaults do not propagate to dependencies'

closure_json="$($skill_dir/scripts/verify_port_closure.zsh --variant +highdepth ImageMagick7)"
assert_jq "$closure_json" '.all_remote_archives_verified == false and ([.hard_blocks[].code] | index("closure_archive_unverified") != null)' 'missing required transitive feature archive is a hard block'
assert_jq "$closure_json" '(.effective_variants[] | select(.name == "ImageMagick7")) | .propagated == [] and .selected == ["+openexr","+x11"]' 'dependency-only variant is not added to a root that lacks it'
assert_jq "$closure_json" '(.effective_variants[] | select(.name == "giflib")) | .propagated == ["+highdepth"] and .selected == ["+highdepth"]' 'explicit dependency-only variant propagates to a supporting dependency'

closure_json="$($skill_dir/scripts/verify_port_closure.zsh --variant +x11 ImageMagick7)"
assert_jq "$closure_json" '.all_remote_archives_verified == false and ([.hard_blocks[].code] | index("closure_archive_unverified") != null)' 'missing propagated variant archive is a hard block'
assert_jq "$closure_json" '(.effective_variants[] | select(.name == "ImageMagick7") | .selected) == ["+openexr","+x11"]' 'root defaults and requested variants are merged'
assert_jq "$closure_json" '(.effective_variants[] | select(.name == "giflib")) | .defaults == [] and .propagated == ["+x11"] and .selected == ["+x11"]' 'root variant propagates to a supporting dependency'
assert_jq "$closure_json" '(.archives[] | select(.port.name == "giflib")) | .port.variants == ["+x11"] and .archive_structure_verified == false' 'archive helper receives propagated dependency variant'

print -r -- '@portvariant +x11' >> "$giflib_closure_root/+CONTENTS"
(cd "$giflib_closure_root" && tar -cjf "$giflib_closure_dir/$giflib_x11_name" +CONTENTS)
print -r -- 'fixture signature' > "$giflib_closure_dir/$giflib_x11_name.rmd160"
print -r -- "$giflib_x11_name" >> "$temp_dir/closure-propagated-index.html"
closure_json="$($skill_dir/scripts/verify_port_closure.zsh --variant +x11 ImageMagick7)"
assert_jq "$closure_json" '.all_remote_archives_verified == true and .hard_blocks == [] and .errors == []' 'propagated variant archive closes the binary-only plan'
unset IHBM_ARCHIVE_BASE_URL IHBM_ARCHIVE_INDEX_FILE IHBM_CLOSURE_PLAN IHBM_PORT_INACTIVE

: > "$IHBM_CALL_LOG"
typeset orphan_json
orphan_json="$($skill_dir/scripts/plan_orphans.zsh --retire app --protect pcre2)"
assert_jq "$orphan_json" '.schema_version == 1 and .mutations_performed == false and .live_recheck_required_before_each_uninstall == true' 'orphan planner read-only contract'
assert_jq "$orphan_json" '.removal_rounds == [["app"],["leaf2","liba"],["libb"]]' 'orphan removal rounds preserve multiple array elements'
assert_jq "$orphan_json" '[.blocked[] | select(.formula == "pcre2") | .reasons[]] | index("explicit_protect") != null' 'explicit protection'
assert_jq "$orphan_json" '[.blocked[] | select(.formula == "reqdep") | .reasons[]] | index("directly_requested") != null' 'direct request protection'
assert_jq "$orphan_json" '[.blocked[] | select(.formula == "shared") | .installed_dependents[]] | index("external") != null' 'external dependent protection'
assert_jq "$orphan_json" '[.blocked[] | select(.formula == "cyc1") | .reasons[]] | index("dependency_cycle") != null' 'dependency cycle detection'
[[ "$(grep -c '^brew info --json=v2 --installed$' "$IHBM_CALL_LOG")" == 1 ]] || fail 'installed receipt snapshot was not called exactly once'
assertions=$((assertions + 1))
[[ "$(grep -c '^brew deps --formula --full-name --include-build --include-test app$' "$IHBM_CALL_LOG")" == 1 ]] || fail 'batched root closure was not called exactly once'
assertions=$((assertions + 1))
assert_log_absent 'brew deps .*--recursive' 'removed brew deps --recursive option was used'
assert_log_absent 'brew (uninstall|autoremove|cleanup)' 'orphan planner attempted a Homebrew mutation'
assert_log_absent '^port .*install' 'orphan planner attempted a MacPorts mutation'

typeset inventory="$temp_dir/inventory.json"
typeset plan="$temp_dir/plan.json"
typeset invalid_plan="$temp_dir/invalid-plan.json"
typeset validation_json preflight_json plan_digest

$skill_dir/scripts/collect_inventory.zsh --formula app >"$inventory"
assert_jq "$(<"$inventory")" '.schema_version == 2 and .mutations_performed == false and .host.architecture == "x86_64"' 'inventory host and read-only contract'
assert_jq "$(<"$inventory")" '.scope.selector == "formula" and .scope.seeds == ["app"] and (.scope.cohort_formulae | index("app") != null)' 'one target uses the universal target-set flow'
assert_jq "$(<"$inventory")" '(.scope.cohort_formulae | index("libb") != null) and (.scope.cohort_formulae | index("external") != null)' 'target set expands dependency and reverse-dependency cohort'
assert_jq "$(<"$inventory")" '.casks == [{token:"casktool",full_token:"casktool",formula_requirements:["app"]}]' 'casks remain evidence only'
assert_jq "$(<"$inventory")" '(.digests.environment|length)==64 and (.digests.ownership|length)==64 and (.digests.evidence|length)==64' 'inventory evidence is digest bound'

jq '{schema_version:2,
  inventory_evidence_digest:.digests.evidence,
  environment_digest:.digests.environment,
  ownership_digest:.digests.ownership,
  decisions:[.scope.cohort_formulae[] | {formula:.,disposition:"deferred",evidence_refs:["fixture"],reason:"fixture-only plan"}],
  transitions:[]}' "$inventory" >"$plan"
plan_digest="$(jq -cS . "$plan" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
jq --arg digest "$plan_digest" '. + {plan_digest:$digest}' "$plan" >"$plan.next"
mv "$plan.next" "$plan"

validation_json="$($skill_dir/scripts/validate_plan.zsh --inventory "$inventory" --plan "$plan")"
assert_jq "$validation_json" '.valid == true and .hard_blocks == [] and .mutations_performed == false' 'complete target-set plan validates'

preflight_json="$($skill_dir/scripts/preflight_apply.zsh --inventory "$inventory" --plan "$plan" --plan-sha256 "$plan_digest")"
assert_jq "$preflight_json" '.authorized_by_evidence == true and .explicit_user_approval_still_required == true and .mutations_performed == false' 'apply preflight revalidates live evidence without authorizing itself'

jq '.decisions[0].command="brew uninstall app" | del(.plan_digest)' "$plan" >"$invalid_plan"
typeset invalid_digest
invalid_digest="$(jq -cS . "$invalid_plan" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
jq --arg digest "$invalid_digest" '. + {plan_digest:$digest}' "$invalid_plan" >"$invalid_plan.next"
mv "$invalid_plan.next" "$invalid_plan"
set +e
validation_json="$($skill_dir/scripts/validate_plan.zsh --inventory "$inventory" --plan "$invalid_plan")"
typeset invalid_exit=$?
set -e
[[ "$invalid_exit" == 4 ]] || fail 'plan containing an executable command key was accepted'
assert_jq "$validation_json" '.valid == false and ([.hard_blocks[].code] | index("forbidden_plan_key") != null)' 'plan command injection is rejected'

set +e
$skill_dir/scripts/collect_inventory.zsh --formula -danger >"$temp_dir/rejected.json" 2>"$temp_dir/rejected.err"
typeset selector_exit=$?
set -e
[[ "$selector_exit" == 2 ]] || fail 'option-like formula selector was accepted'
assertions=$((assertions + 1))

typeset upstream_copy="$temp_dir/rg"
cp "$fixture_root/opt/local/bin/rg" "$upstream_copy"
chmod 0755 "$upstream_copy"
typeset upstream_sha upstream_json
upstream_sha="$(/usr/bin/shasum -a 256 "$upstream_copy" | /usr/bin/awk '{print $1}')"
upstream_json="$($skill_dir/scripts/verify_upstream_binary.zsh --file "$upstream_copy" --expected-sha256 "$upstream_sha")"
assert_jq "$upstream_json" '.artifact.digest_matches == true and .binary_executed == false and .mutations_performed == false' 'upstream artifact is inspected without execution'
upstream_json="$($skill_dir/scripts/verify_upstream_binary.zsh --file "$upstream_copy" --expected-sha256 0000000000000000000000000000000000000000000000000000000000000000)"
assert_jq "$upstream_json" '[.hard_blocks[].code] | index("sha256_mismatch") != null' 'upstream digest mismatch is a hard block'

assert_log_absent 'brew (uninstall|autoremove|cleanup)' 'target-set helpers attempted a Homebrew mutation'
assert_log_absent '^port .*install' 'target-set helpers attempted a MacPorts mutation'

print -r -- "PASS: $assertions assertions"
