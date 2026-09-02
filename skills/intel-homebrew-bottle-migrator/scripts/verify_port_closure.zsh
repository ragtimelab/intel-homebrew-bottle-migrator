#!/bin/zsh

set -u
setopt extendedglob pipefail
umask 077
export LC_ALL=C

typeset -a root_variants errors hard_blocks archive_items variant_items pids reply
typeset temp_dir=''

usage() {
  print -u2 'usage: verify_port_closure.zsh [--variant +NAME|-NAME]... PORT'
}

cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
}

items_json() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -s '.'
  fi
}

add_error() {
  errors+=("$(jq -n --arg stage "$1" --arg detail "$2" '{stage:$stage,detail:$detail}')")
}

add_hard_block() {
  hard_blocks+=("$(jq -n --arg code "$1" --arg detail "$2" '{code:$code,detail:$detail}')")
}

while (( $# > 0 )); do
  case "$1" in
    --variant)
      (( $# >= 2 )) || { usage; exit 2; }
      root_variants+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) usage; exit 2 ;;
    *) break ;;
  esac
done

(( $# == 1 )) || { usage; exit 2; }
typeset root_port="$1"
[[ "$root_port" == [A-Za-z0-9._+-]## ]] || { print -u2 'invalid port name'; exit 2; }
for root_variant in "${root_variants[@]}"; do
  [[ "$root_variant" == [+-][A-Za-z0-9._+-]## ]] || { print -u2 "invalid variant: $root_variant"; exit 2; }
done

typeset jq_bin port_bin skill_dir archive_helper
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  port_bin="${IHBM_PORT_BIN:-$(command -v port 2>/dev/null || true)}"
else
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
  port_bin=/opt/local/bin/port
fi
skill_dir="${0:A:h:h}"
archive_helper="$skill_dir/scripts/verify_port_archive.zsh"
[[ -n "$jq_bin" && -n "$port_bin" && -x "$archive_helper" ]] || {
  print -u2 'jq, port, and executable verify_port_archive.zsh are required'
  exit 2
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ihbm-closure.XXXXXX")" || exit 3
trap cleanup EXIT INT TERM

typeset recorded_utc recorded_local product_version build_version architecture kernel_release manager_version
recorded_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
recorded_local="$(/bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
product_version="$(/usr/bin/sw_vers -productVersion)"
build_version="$(/usr/bin/sw_vers -buildVersion)"
architecture="$(/usr/bin/uname -m)"
kernel_release="$(/usr/bin/uname -r)"
[[ "$architecture" == x86_64 ]] || add_hard_block 'unsupported_architecture' "expected x86_64, found $architecture"
manager_version="$($port_bin version 2>/dev/null | sed -n 's/^Version: //p')"

typeset active_before requested_before root_installed plan_stdout plan_stderr plan_exit
active_before="$($port_bin installed 2>"$temp_dir/installed.stderr")"
requested_before="$($port_bin echo requested 2>"$temp_dir/requested.stderr")"
root_installed="$($port_bin installed "$root_port" 2>"$temp_dir/root-installed.stderr")"
if print -r -- "$root_installed" | grep -Eq "^[[:space:]]*${root_port}[[:space:]]+@.*[(]active[)]"; then
  plan_stdout='Root is already active; adoption requires no install. Verify the exact root archive only.'
  plan_stderr=''
  plan_exit=0
else
  plan_stdout="$($port_bin -b -y install "$root_port" "${root_variants[@]}" 2>"$temp_dir/plan.stderr")"
  plan_exit=$?
  plan_stderr="$(<"$temp_dir/plan.stderr")"
  if (( plan_exit != 0 )); then
    add_error 'binary_only_plan' "$plan_stderr"
    add_hard_block 'binary_only_plan_failed' "port -b -y install failed for $root_port"
  fi
fi

typeset dependency_line
dependency_line="$(print -r -- "$plan_stdout" | sed -n 's/^--->  Dependencies to be installed: //p' | tr '\n' ' ')"
typeset -a closure_ports
closure_ports=("$root_port")
if [[ -n "$dependency_line" ]]; then
  closure_ports+=("${(z)dependency_line[@]}")
fi
closure_ports=("${(@u)closure_ports}")

resolve_variant_metadata() {
  local closure_port="$1"
  shift
  local -a propagated_selectors=("$@")
  local variant_output variant_exit
  local -a available_variants default_variants selected_variants applied_selectors

  variant_output="$($port_bin variants "$closure_port" 2>"$temp_dir/variants-$closure_port.stderr")"
  variant_exit=$?
  if (( variant_exit != 0 )); then
    add_error "port_variants:$closure_port" "$(<"$temp_dir/variants-$closure_port.stderr")"
    add_hard_block 'closure_variants_unresolved' "$closure_port variants could not be resolved"
  fi

  available_variants=("${(@f)$(print -r -- "$variant_output" | sed -E -n 's/^[[:space:]]*(\[[+-]\][[:space:]]*)?([A-Za-z0-9._+-]+):.*/\2/p')}")
  available_variants=("${(@u)available_variants:#}")
  default_variants=("${(@f)$(print -r -- "$variant_output" | sed -E -n 's/^[[:space:]]*\[\+\][[:space:]]*([A-Za-z0-9._+-]+):.*/+\1/p')}")
  default_variants=("${(@u)default_variants:#}")
  selected_variants=("${default_variants[@]}")

  local selector selector_name
  for selector in "${propagated_selectors[@]}"; do
    selector_name="${selector[2,-1]}"
    if (( ${available_variants[(Ie)$selector_name]} > 0 )); then
      selected_variants=("${selected_variants[@]:#+$selector_name}")
      applied_selectors+=("$selector")
      [[ "$selector" == +* ]] && selected_variants+=("+$selector_name")
    fi
  done
  selected_variants=("${(@u)selected_variants:#}")
  applied_selectors=("${(@u)applied_selectors:#}")

  local available_json defaults_json propagated_json selected_json
  available_json="$(printf '%s\n' "${available_variants[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
  defaults_json="$(printf '%s\n' "${default_variants[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
  propagated_json="$(printf '%s\n' "${applied_selectors[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
  selected_json="$(printf '%s\n' "${selected_variants[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
  variant_items+=("$($jq_bin -n --arg name "$closure_port" --argjson available "$available_json" \
    --argjson defaults "$defaults_json" --argjson propagated "$propagated_json" \
    --argjson selected "$selected_json" \
    '{name:$name,available:$available,defaults:$defaults,propagated:$propagated,selected:$selected}')")

  reply=("${selected_variants[@]}")
}

typeset -a root_effective_variants root_selectors
resolve_variant_metadata "$root_port" "${root_variants[@]}"
root_effective_variants=("${reply[@]}")
root_selectors=("${root_variants[@]}")
root_selectors=("${(@u)root_selectors:#}")

typeset -i index=0
for closure_port in "${closure_ports[@]}"; do
  index=$((index + 1))
  typeset -a variants args
  if [[ "$closure_port" == "$root_port" ]]; then
    variants=("${root_effective_variants[@]}")
  else
    resolve_variant_metadata "$closure_port" "${root_selectors[@]}"
    variants=("${reply[@]}")
  fi
  args=()
  for variant in "${variants[@]}"; do
    [[ -n "$variant" ]] && args+=(--variant "$variant")
  done
  (
    "$archive_helper" "${args[@]}" "$closure_port" >"$temp_dir/$index.json" 2>"$temp_dir/$index.stderr"
    print -r -- "$?" >"$temp_dir/$index.exit"
  ) &
  pids+=("$!")
  if (( ${#pids} >= 2 )); then
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
    pids=()
  fi
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

typeset all_remote_archives_verified=true
for (( index=1; index<=${#closure_ports}; index++ )); do
  typeset closure_port="${closure_ports[$index]}"
  typeset archive_json=''
  [[ -f "$temp_dir/$index.json" ]] && archive_json="$(<"$temp_dir/$index.json")"
  if [[ -z "$archive_json" ]] || ! print -r -- "$archive_json" | $jq_bin -e . >/dev/null 2>&1; then
    typeset helper_stderr=''
    [[ -f "$temp_dir/$index.stderr" ]] && helper_stderr="$(<"$temp_dir/$index.stderr")"
    add_error "archive_helper:$closure_port" "${helper_stderr:-helper produced no valid JSON}"
    add_hard_block 'closure_archive_unverified' "$closure_port archive verification failed"
    all_remote_archives_verified=false
    continue
  fi
  archive_items+=("$archive_json")
  if ! print -r -- "$archive_json" | $jq_bin -e '.archive_structure_verified == true and .hard_blocks == [] and .errors == []' >/dev/null; then
    add_hard_block 'closure_archive_unverified' "$closure_port has an unavailable or invalid public archive"
    all_remote_archives_verified=false
  fi
done

(( ${#errors} == 0 && ${#hard_blocks} == 0 )) || all_remote_archives_verified=false

typeset variants_json ports_json effective_variants_json archives_json errors_json hard_blocks_json plan_json
variants_json="$(printf '%s\n' "${root_variants[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
ports_json="$(printf '%s\n' "${closure_ports[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
effective_variants_json="$(items_json "${variant_items[@]}")"
archives_json="$(items_json "${archive_items[@]}")"
errors_json="$(items_json "${errors[@]}")"
hard_blocks_json="$(items_json "${hard_blocks[@]}")"
plan_json="$($jq_bin -n --argjson exit_code "$plan_exit" --arg stdout "$plan_stdout" --arg stderr "$plan_stderr" \
  '{state:(if $exit_code == 0 then "completed" else "failed" end),exit_code:$exit_code,stdout:$stdout,stderr:$stderr,truncated:false}')"

$jq_bin -n \
  --argjson schema_version 3 \
  --arg recorded_utc "$recorded_utc" --arg recorded_local "$recorded_local" \
  --arg product_version "$product_version" --arg build_version "$build_version" \
  --arg architecture "$architecture" --arg kernel_release "$kernel_release" \
  --arg manager_version "$manager_version" --arg root_port "$root_port" \
  --argjson root_variants "$variants_json" --argjson ports "$ports_json" \
  --arg active_before "$active_before" --arg requested_before "$requested_before" \
  --argjson plan "$plan_json" --argjson effective_variants "$effective_variants_json" --argjson archives "$archives_json" \
  --argjson verified "$all_remote_archives_verified" \
  --argjson hard_blocks "$hard_blocks_json" --argjson errors "$errors_json" \
  '{schema_version:$schema_version,recorded_at:{utc:$recorded_utc,local:$recorded_local},
    host:{product_version:$product_version,build_version:$build_version,architecture:$architecture,kernel_release:$kernel_release},
    macports:{manager_version:$manager_version,root:{name:$root_port,requested_variants:$root_variants},active_snapshot:$active_before,requested_snapshot:$requested_before,binary_only_plan:$plan},
    closure_ports:$ports,effective_variants:$effective_variants,archives:$archives,all_remote_archives_verified:$verified,
    requires_port_b_install:true,mutations_performed:false,hard_blocks:$hard_blocks,errors:$errors}'
