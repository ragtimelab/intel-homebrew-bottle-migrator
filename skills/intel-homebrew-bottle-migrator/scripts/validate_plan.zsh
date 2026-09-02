#!/bin/zsh

set -eu
setopt pipefail no_unset
umask 077
export LC_ALL=C

usage() { print -u2 'usage: validate_plan.zsh --inventory FILE --plan FILE'; }

typeset inventory_file='' plan_file=''
while (( $# > 0 )); do
  case "$1" in
    --inventory) (( $# >= 2 )) || { usage; exit 2; }; inventory_file="$2"; shift 2 ;;
    --plan) (( $# >= 2 )) || { usage; exit 2; }; plan_file="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$inventory_file" && -r "$plan_file" ]] || { usage; exit 2; }

typeset jq_bin
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
else
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
fi
[[ -n "${jq_bin:-}" && -x "$jq_bin" ]] || { print -u2 'trusted jq executable not found'; exit 2; }

$jq_bin -e '.schema_version == 2 and .mutations_performed == false and (.scope.cohort_formulae|type)=="array"' "$inventory_file" >/dev/null || { print -u2 'invalid inventory schema'; exit 3; }
$jq_bin -e '.schema_version == 2 and (.decisions|type)=="array" and (.transitions|type)=="array" and (.plan_digest|type)=="string"' "$plan_file" >/dev/null || { print -u2 'invalid plan schema'; exit 3; }

typeset calculated_digest supplied_digest validation_json valid
calculated_digest="$($jq_bin -cS 'del(.plan_digest)' "$plan_file" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
supplied_digest="$($jq_bin -r '.plan_digest' "$plan_file")"

validation_json="$($jq_bin -n --slurpfile inventory "$inventory_file" --slurpfile plan "$plan_file" --arg calculated "$calculated_digest" --arg supplied "$supplied_digest" '
  def forbidden_keys:
    [paths(scalars) as $p
      | ($p[-1] | tostring | ascii_downcase) as $key
      | select($key | IN("command","shell","script","password","token","secret","authorization"))
      | ($p | map(tostring) | join("."))];
  ["macports_binary","official_upstream_binary","retire_duplicate","retire_orphan","adaptation_required","deferred","blocked_security"] as $allowed_dispositions
  | ["install_macports_binary","install_official_upstream_binary","adapt_consumer","verify_candidate","unlink_homebrew","verify_fresh_login","uninstall_homebrew","retire_orphan","final_verify"] as $allowed_transitions
  | ($inventory[0].scope.cohort_formulae | sort | unique) as $cohort
  | ($plan[0].decisions | map(.formula) | sort | unique) as $decided
  | ($plan[0] | forbidden_keys) as $forbidden
  | [
      if $plan[0].inventory_evidence_digest == $inventory[0].digests.evidence then empty else {code:"evidence_digest_mismatch"} end,
      if $plan[0].environment_digest == $inventory[0].digests.environment then empty else {code:"environment_digest_mismatch"} end,
      if $plan[0].ownership_digest == $inventory[0].digests.ownership then empty else {code:"ownership_digest_mismatch"} end,
      if $supplied == $calculated then empty else {code:"plan_digest_mismatch"} end,
      if $decided == $cohort and ($plan[0].decisions|length) == ($cohort|length) then empty else {code:"incomplete_or_duplicate_decisions",expected:$cohort,actual:$decided} end,
      ($plan[0].decisions[] | select((.disposition as $d | $allowed_dispositions | index($d)) == null) | {code:"invalid_disposition",formula,disposition}),
      ($plan[0].transitions[] | select((.type as $t | $allowed_transitions | index($t)) == null) | {code:"invalid_transition",type}),
      ($forbidden[] | {code:"forbidden_plan_key",path:.})
    ] as $blocks
  | {schema_version:2,valid:($blocks|length==0),calculated_plan_digest:$calculated,hard_blocks:$blocks,mutations_performed:false}')"

print -r -- "$validation_json"
valid="$(print -rn -- "$validation_json" | $jq_bin -r '.valid')"
[[ "$valid" == true ]] || exit 4
