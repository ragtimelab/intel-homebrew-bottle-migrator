#!/bin/zsh

set -u
setopt extendedglob
umask 077
export LC_ALL=C
export HOMEBREW_NO_AUTO_UPDATE=1

usage() {
  print -u2 'usage: plan_orphans.zsh --retire FORMULA [--retire FORMULA]... [--protect FORMULA]...'
}

debug_stage() {
  [[ "${IHBM_DEBUG_TIMING:-0}" == 1 ]] && print -u2 -- "plan_orphans stage=$1 seconds=$SECONDS"
}

json_error() {
  local message="$1"
  local code="$2"
  jq -n --arg error "$message" --argjson exit_code "$code" \
    '{schema_version:1,error:$error,exit_code:$exit_code,mutations_performed:false}'
  exit "$code"
}

strings_json() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0)) | unique'
  fi
}

json_items() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -s '.'
  fi
}

typeset -a raw_retire raw_protect retire_roots protected closure
while (( $# > 0 )); do
  case "$1" in
    --retire)
      (( $# >= 2 )) || { usage; exit 2; }
      raw_retire+=("$2")
      shift 2
      ;;
    --protect)
      (( $# >= 2 )) || { usage; exit 2; }
      raw_protect+=("$2")
      shift 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
(( ${#raw_retire} > 0 )) || { usage; exit 2; }

typeset brew_bin jq_bin
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  brew_bin="${IHBM_BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
else
  brew_bin=/usr/local/bin/brew
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
fi
[[ -n "$jq_bin" ]] || { print -u2 'jq is required'; exit 2; }
[[ -n "$brew_bin" ]] || json_error 'Homebrew is not available' 3

typeset temp_dir
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ihbm-orphans.XXXXXX")" || json_error 'cannot create temporary directory' 3
cleanup() { [[ -d "$temp_dir" ]] && rm -rf -- "$temp_dir"; }
trap cleanup EXIT INT TERM

typeset installed_json
if ! installed_json="$($brew_bin info --json=v2 --installed 2>"$temp_dir/installed.err")"; then
  json_error 'cannot read installed Homebrew receipts' 3
fi
print -rn -- "$installed_json" | "$jq_bin" -e '.formulae | type == "array"' >/dev/null 2>&1 || \
  json_error 'installed Homebrew JSON is invalid' 3
debug_stage installed_snapshot

typeset -A installed_alias_map
typeset installed_short_name installed_full_name
while IFS=$'\t' read -r installed_short_name installed_full_name; do
  [[ -n "$installed_short_name" && -n "$installed_full_name" ]] || continue
  installed_alias_map[$installed_short_name]="$installed_full_name"
  installed_alias_map[$installed_full_name]="$installed_full_name"
done < <(print -rn -- "$installed_json" | "$jq_bin" -r '
  .formulae[] | [.name, (.full_name // .name)] | @tsv')

typeset raw_name formula_json canonical_name deps_output
for raw_name in "${raw_retire[@]}"; do
  [[ "$raw_name" == [A-Za-z0-9._+@/-]## ]] || json_error "invalid formula name: $raw_name" 2
  if [[ -n "${installed_alias_map[$raw_name]-}" ]]; then
    canonical_name="${installed_alias_map[$raw_name]}"
  else
    if ! formula_json="$($brew_bin info --json=v2 "$raw_name" 2>"$temp_dir/info.err")"; then
      json_error "unknown or unavailable Homebrew formula: $raw_name" 3
    fi
    if (( $(print -rn -- "$formula_json" | "$jq_bin" '.formulae | length') == 0 )); then
      if (( $(print -rn -- "$formula_json" | "$jq_bin" '.casks | length') > 0 )); then
        json_error "$raw_name is a Homebrew cask and is outside this skill" 4
      fi
      json_error "unknown or unavailable Homebrew formula: $raw_name" 3
    fi
    canonical_name="$(print -rn -- "$formula_json" | "$jq_bin" -r '.formulae[0].full_name // .formulae[0].name')"
  fi
  retire_roots+=("$canonical_name")
  closure+=("$canonical_name")
done

# Homebrew accepts multiple formula roots in one dependency query. Preserve the
# build/test closure contract while paying the subprocess and metadata cost
# once for the entire retirement wave.
if ! deps_output="$($brew_bin deps --formula --full-name --include-build --include-test "${retire_roots[@]}" 2>"$temp_dir/deps.err")"; then
  json_error 'cannot compute dependency closure for retirement roots' 3
fi
closure+=("${(@f)deps_output}")
debug_stage dependency_closure

for raw_name in "${raw_protect[@]}"; do
  [[ "$raw_name" == [A-Za-z0-9._+@/-]## ]] || json_error "invalid formula name: $raw_name" 2
  if [[ -n "${installed_alias_map[$raw_name]-}" ]]; then
    protected+=("${installed_alias_map[$raw_name]}")
    continue
  fi
  if ! formula_json="$($brew_bin info --json=v2 "$raw_name" 2>"$temp_dir/protect-info.err")"; then
    json_error "unknown or unavailable protected formula: $raw_name" 3
  fi
  if (( $(print -rn -- "$formula_json" | "$jq_bin" '.formulae | length') == 0 )); then
    json_error "protected target is not a formula: $raw_name" 4
  fi
  protected+=("$(print -rn -- "$formula_json" | "$jq_bin" -r '.formulae[0].full_name // .formulae[0].name')")
done

retire_roots=("${(@u)retire_roots}")
protected=("${(@u)protected}")
closure=("${(@u)closure}")
debug_stage roots_resolved

typeset -A installed_map requested_map dependency_map dependency_csv_map retire_map protect_map closure_map active_map candidate_map removed_map remaining_map
typeset formula_name requested_value dependency_csv
while IFS=$'\t' read -r formula_name requested_value dependency_csv; do
  [[ -n "$formula_name" ]] || continue
  installed_map[$formula_name]=1
  active_map[$formula_name]=1
  requested_map[$formula_name]="$requested_value"
  dependency_csv_map[$formula_name]="$dependency_csv"
  dependency_map[$formula_name]="|${dependency_csv//,/|}|"
done < <(print -rn -- "$installed_json" | "$jq_bin" -r '
  .formulae[] |
  (.full_name // .name) as $name |
  ([.installed[]?.installed_on_request == true] | any) as $requested |
  ([.installed[-1].runtime_dependencies[]?.full_name] | unique | join(",")) as $dependencies |
  [$name, ($requested | tostring), $dependencies] | @tsv')
debug_stage installed_maps

for formula_name in "${retire_roots[@]}"; do retire_map[$formula_name]=1; done
for formula_name in "${protected[@]}"; do protect_map[$formula_name]=1; done

# Resolve the installed runtime dependency closure from one receipt snapshot.
# This keeps target-set planning O(1) in Homebrew subprocesses instead of
# launching `brew info` and `brew deps` once per retirement root.
typeset -a closure_queue dependency_names
typeset -i closure_index=1
for formula_name in "${closure[@]}"; do
  [[ -n "$formula_name" ]] && closure_map[$formula_name]=1
done
closure_queue=("${retire_roots[@]}")
while (( closure_index <= ${#closure_queue} )); do
  formula_name="${closure_queue[$closure_index]}"
  (( closure_index++ ))
  [[ -n "${installed_map[$formula_name]-}" ]] || continue
  dependency_csv="${dependency_csv_map[$formula_name]-}"
  [[ -n "$dependency_csv" ]] || continue
  dependency_names=("${(@s:,:)dependency_csv}")
  for canonical_name in "${dependency_names[@]}"; do
    [[ -n "$canonical_name" ]] || continue
    if [[ -z "${closure_map[$canonical_name]-}" ]]; then
      closure+=("$canonical_name")
      closure_map[$canonical_name]=1
      closure_queue+=("$canonical_name")
    fi
  done
done
closure=("${(@u)closure}")
debug_stage installed_closure

typeset -a already_absent
for formula_name in "${retire_roots[@]}"; do
  [[ -n "${installed_map[$formula_name]-}" ]] || already_absent+=("$formula_name")
done
debug_stage absent_roots

for formula_name in ${(k)installed_map}; do
  [[ -n "${closure_map[$formula_name]-}" ]] || continue
  [[ -z "${protect_map[$formula_name]-}" ]] || continue
  if [[ -n "${retire_map[$formula_name]-}" || "${requested_map[$formula_name]-false}" != true ]]; then
    candidate_map[$formula_name]=1
    remaining_map[$formula_name]=1
  fi
done
debug_stage candidates

typeset -a round_json_items removal_rounds_json_items
typeset -i changed=1 round_iteration=0 remaining_before=0 remaining_after=0
while (( changed )); do
  (( round_iteration++ ))
  remaining_before=${#remaining_map}
  changed=0
  typeset -a round_names=()
  typeset candidate='' depender='' has_dependent=false
  for candidate in ${(ok)remaining_map}; do
    has_dependent=false
    for depender in ${(k)active_map}; do
      [[ "$depender" == "$candidate" ]] && continue
      if [[ "${dependency_map[$depender]-||}" == *"|$candidate|"* ]]; then
        has_dependent=true
        break
      fi
    done
    [[ "$has_dependent" == false ]] && round_names+=("$candidate")
  done
  if (( ${#round_names} > 0 )); then
    changed=1
    round_names=("${(@on)round_names}")
    removal_rounds_json_items+=("$(strings_json "${round_names[@]}")")
    for candidate in "${round_names[@]}"; do
      unset "active_map[$candidate]"
      unset "remaining_map[$candidate]"
      removed_map[$candidate]=1
    done
  fi
  remaining_after=${#remaining_map}
  if [[ "${IHBM_DEBUG_TIMING:-0}" == 1 ]]; then
    print -u2 -- "plan_orphans round=$round_iteration before=$remaining_before removable=${#round_names[@]} names=${(j:,:)round_names} after=$remaining_after seconds=$SECONDS"
  fi
  if (( ${#round_names[@]} > 0 && remaining_after >= remaining_before )); then
    json_error 'orphan planner made no progress while applying a removal round' 5
  fi
  if (( round_iteration > ${#installed_map} + 1 )); then
    json_error 'orphan planner exceeded the installed-formula round bound' 5
  fi
done
debug_stage removal_rounds

typeset -a blocked_items
typeset -a reasons dependents
for formula_name in ${(ok)installed_map}; do
  [[ -n "${closure_map[$formula_name]-}" ]] || continue
  [[ -z "${removed_map[$formula_name]-}" ]] || continue
  reasons=()
  dependents=()
  [[ -n "${protect_map[$formula_name]-}" ]] && reasons+=(explicit_protect)
  if [[ "${requested_map[$formula_name]-false}" == true && -z "${retire_map[$formula_name]-}" ]]; then
    reasons+=(directly_requested)
  fi
  for depender in ${(ok)active_map}; do
    [[ "$depender" == "$formula_name" ]] && continue
    [[ "${dependency_map[$depender]-||}" == *"|$formula_name|"* ]] && dependents+=("$depender")
  done
  (( ${#dependents} > 0 )) && reasons+=(installed_dependents)
  if [[ -n "${remaining_map[$formula_name]-}" && ${#dependents} -gt 0 ]]; then
    typeset all_internal=true
    for depender in "${dependents[@]}"; do
      if [[ -z "${remaining_map[$depender]-}" ]]; then
        all_internal=false
        break
      fi
    done
    [[ "$all_internal" == true ]] && reasons+=(dependency_cycle)
  fi
  (( ${#reasons} > 0 )) || reasons+=(not_removable_from_snapshot)
  blocked_items+=("$(jq -n \
    --arg formula "$formula_name" \
    --argjson reasons "$(strings_json "${reasons[@]}")" \
    --argjson installed_dependents "$(strings_json "${dependents[@]}")" \
    '{formula:$formula,reasons:$reasons,installed_dependents:$installed_dependents}')")
done
debug_stage blocked_items

typeset retire_json absent_json protected_json closure_json rounds_json blocked_json
retire_json="$(strings_json "${retire_roots[@]}")"
absent_json="$(strings_json "${already_absent[@]}")"
protected_json="$(strings_json "${protected[@]}")"
closure_json="$(strings_json "${closure[@]}")"
rounds_json="$(json_items "${removal_rounds_json_items[@]}")"
blocked_json="$(json_items "${blocked_items[@]}")"

"$jq_bin" -n \
  --argjson schema_version 1 \
  --arg recorded_utc "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg recorded_local "$(/bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)')" \
  --argjson retire_roots "$retire_json" \
  --argjson already_absent_roots "$absent_json" \
  --argjson protected "$protected_json" \
  --argjson closure "$closure_json" \
  --argjson removal_rounds "$rounds_json" \
  --argjson blocked "$blocked_json" \
  '{
    schema_version:$schema_version,
    recorded_at:{utc:$recorded_utc,local:$recorded_local},
    retire_roots:$retire_roots,
    already_absent_roots:$already_absent_roots,
    protected:$protected,
    closure:$closure,
    removal_rounds:$removal_rounds,
    blocked:$blocked,
    live_recheck_required_before_each_uninstall:true,
    mutations_performed:false,
    errors:[]
  }'
