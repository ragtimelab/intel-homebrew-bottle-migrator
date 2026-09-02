#!/bin/zsh

set -eu
setopt pipefail no_unset extendedglob
umask 077
export LC_ALL=C

usage() { print -u2 'usage: preflight_apply.zsh --inventory FILE --plan FILE --plan-sha256 DIGEST'; }

typeset inventory_file='' plan_file='' approved_digest=''
while (( $# > 0 )); do
  case "$1" in
    --inventory) (( $# >= 2 )) || { usage; exit 2; }; inventory_file="$2"; shift 2 ;;
    --plan) (( $# >= 2 )) || { usage; exit 2; }; plan_file="$2"; shift 2 ;;
    --plan-sha256) (( $# >= 2 )) || { usage; exit 2; }; approved_digest="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$inventory_file" && -r "$plan_file" && "$approved_digest" == [0-9a-f]## ]] || { usage; exit 2; }

typeset skill_dir jq_bin temp_inventory plan_digest selector
skill_dir="${0:A:h:h}"
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
else
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
fi
[[ -n "${jq_bin:-}" && -x "$jq_bin" ]] || { print -u2 'trusted jq executable not found'; exit 2; }

plan_digest="$($jq_bin -r '.plan_digest' "$plan_file")"
[[ "$approved_digest" == "$plan_digest" ]] || { print -u2 'approved plan digest mismatch'; exit 3; }
"$skill_dir/scripts/validate_plan.zsh" --inventory "$inventory_file" --plan "$plan_file" >/dev/null

temp_inventory="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ihbm-preflight.XXXXXX")"
cleanup() { [[ -f "$temp_inventory" ]] && /bin/rm -f -- "$temp_inventory"; }
trap cleanup EXIT INT TERM

selector="$($jq_bin -r '.scope.selector' "$inventory_file")"
typeset -a collector_args=()
if [[ "$selector" == all ]]; then
  collector_args=(--all)
else
  collector_args=()
  while IFS= read -r formula_name; do
    [[ -n "$formula_name" ]] && collector_args+=(--formula "$formula_name")
  done < <($jq_bin -r '.scope.requested[]' "$inventory_file")
fi
"$skill_dir/scripts/collect_inventory.zsh" "${collector_args[@]}" >"$temp_inventory"

$jq_bin -n --slurpfile previous "$inventory_file" --slurpfile live "$temp_inventory" --arg digest "$approved_digest" '
  [
    if $previous[0].digests.environment == $live[0].digests.environment then empty else {code:"environment_drift"} end,
    if $previous[0].digests.ownership == $live[0].digests.ownership then empty else {code:"ownership_drift"} end,
    if $previous[0].digests.evidence == $live[0].digests.evidence then empty else {code:"evidence_drift"} end,
    if ($previous[0].scope.cohort_formulae|sort) == ($live[0].scope.cohort_formulae|sort) then empty else {code:"cohort_drift"} end,
    ($live[0].hard_blocks[])
  ] as $blocks
  | {schema_version:2,approved_plan_digest:$digest,authorized_by_evidence:($blocks|length==0),explicit_user_approval_still_required:true,hard_blocks:$blocks,live_digests:$live[0].digests,mutations_performed:false}'
