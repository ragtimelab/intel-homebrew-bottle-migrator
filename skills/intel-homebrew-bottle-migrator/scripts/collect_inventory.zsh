#!/bin/zsh

set -eu
setopt pipefail no_unset extendedglob
umask 077
export LC_ALL=C
export HOMEBREW_NO_AUTO_UPDATE=1

usage() {
  print -u2 'usage: collect_inventory.zsh (--formula FORMULA [--formula FORMULA ...] | --all)'
}

valid_formula() {
  local value="$1"
  (( ${#value} > 0 && ${#value} <= 200 )) || return 1
  [[ "$value" != -* && "$value" != *'..'* && "$value" == [A-Za-z0-9._+@/-]## ]]
}

typeset selector='formula'
typeset -a requested=()
while (( $# > 0 )); do
  case "$1" in
    --formula)
      (( $# >= 2 )) || { usage; exit 2; }
      [[ "$selector" != all ]] || { usage; exit 2; }
      valid_formula "$2" || { print -u2 -- "invalid formula: $2"; exit 2; }
      requested+=("$2")
      shift 2
      ;;
    --all)
      (( ${#requested} == 0 )) || { usage; exit 2; }
      selector='all'
      shift
      ;;
    --)
      shift
      break
      ;;
    *) usage; exit 2 ;;
  esac
done
(( $# == 0 )) || { usage; exit 2; }
[[ "$selector" == all || ${#requested} -gt 0 ]] || { usage; exit 2; }

typeset jq_bin brew_bin port_bin=''
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  brew_bin="${IHBM_BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
  port_bin="${IHBM_PORT_BIN:-$(command -v port 2>/dev/null || true)}"
else
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
  brew_bin=/usr/local/bin/brew
  [[ -x /opt/local/bin/port ]] && port_bin=/opt/local/bin/port
fi
[[ -n "$jq_bin" && -x "$jq_bin" ]] || { print -u2 'trusted jq executable not found'; exit 2; }
[[ -n "$brew_bin" && -x "$brew_bin" ]] || { print -u2 'Homebrew is required at the trusted Intel prefix'; exit 2; }

typeset architecture product_version build_version kernel_release recorded_utc recorded_local
architecture="$(/usr/bin/uname -m)"
product_version="$(/usr/bin/sw_vers -productVersion)"
build_version="$(/usr/bin/sw_vers -buildVersion)"
kernel_release="$(/usr/bin/uname -r)"
recorded_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
recorded_local="$(/bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)')"

typeset brew_prefix brew_version port_version=''
brew_prefix="$($brew_bin --prefix)"
brew_version="$($brew_bin --version | /usr/bin/sed -n '1p')"
[[ "$brew_prefix" != /opt/local* ]] || { print -u2 'Homebrew and MacPorts prefixes overlap'; exit 3; }
if [[ -n "$port_bin" && -x "$port_bin" ]]; then
  port_version="$($port_bin version 2>/dev/null | /usr/bin/sed -n 's/^Version: //p')"
fi

typeset formula_raw cask_raw normalized_formulae normalized_casks requested_json scope_json
formula_raw="$($brew_bin info --json=v2 --installed)"
if cask_raw="$($brew_bin info --json=v2 --installed --cask 2>/dev/null)"; then
  :
else
  cask_raw='{"casks":[]}'
fi

normalized_formulae="$(print -rn -- "$formula_raw" | $jq_bin '
  [.formulae[] | {
    name,
    full_name:(.full_name // .name),
    linked_keg:(.linked_keg // null),
    outdated:(.outdated // false),
    pinned:(.pinned // false),
    disabled:(.disabled // false),
    deprecated:(.deprecated // false),
    installed_version:(.installed[-1].version // null),
    installed_on_request:(.installed[-1].installed_on_request // false),
    poured_from_bottle:(.installed[-1].poured_from_bottle // false),
    dependencies:((.dependencies // []) | map(split("/")[-1])),
    runtime_dependencies:((.installed[-1].runtime_dependencies // []) | map(.full_name | split("/")[-1]))
  }] | sort_by(.name)')"

normalized_casks="$(print -rn -- "$cask_raw" | $jq_bin '
  [(.casks // [])[] | {
    token,
    full_token:(.full_token // .token),
    formula_requirements:([
      (.depends_on.formula? // empty)
      | if type == "object" then keys[] else . end
    ] | flatten | unique)
  }] | sort_by(.token)')"

if [[ "$selector" == all ]]; then
  requested_json="$(print -rn -- "$normalized_formulae" | $jq_bin '[.[].name]')"
else
  requested_json="$(printf '%s\n' "${requested[@]}" | $jq_bin -R -s 'split("\n") | map(select(length > 0)) | unique')"
fi

scope_json="$($jq_bin -n \
  --arg selector "$selector" \
  --argjson requested "$requested_json" \
  --argjson formulae "$normalized_formulae" \
  --argjson casks "$normalized_casks" '
  def short: split("/")[-1];
  def add_unique($items): reduce $items[] as $item (.;
    if index($item) == null then . + [$item] else . end);
  def step($formulae): . as $set
    | reduce $formulae[] as $f ($set;
        (($f.dependencies + $f.runtime_dependencies) | map(short)) as $deps
        | if ((index($f.name) != null) or any($deps[]; . as $d | ($set | index($d)) != null))
          then add_unique($deps + [$f.name])
          else . end);
  ($formulae | map(.name)) as $installed
  | ($casks | map(.token)) as $installed_casks
  | ($requested | map(short)) as $requested_short
  | ($requested_short | map(select(. as $n | $installed | index($n)))) as $seeds
  | ($requested_short - $seeds) as $not_formulae
  | ($not_formulae | map(select(. as $n | $installed_casks | index($n)))) as $requested_casks
  | ($not_formulae - $requested_casks) as $missing
  | ($seeds | until((step($formulae) | sort) == (sort); step($formulae) | sort)) as $cohort
  | {selector:$selector,requested:$requested,seeds:($seeds|unique),missing:($missing|unique),requested_casks:($requested_casks|unique),cohort_formulae:($cohort|map(select(. as $n | $installed | index($n)))|unique)}')"

typeset environment_body ownership_body environment_digest ownership_digest evidence_body evidence_digest
environment_body="$($jq_bin -cn \
  --arg product "$product_version" --arg build "$build_version" \
  --arg arch "$architecture" --arg kernel "$kernel_release" \
  --arg brew_path "$brew_bin" --arg brew_prefix "$brew_prefix" --arg brew_version "$brew_version" \
  --arg port_path "$port_bin" --arg port_version "$port_version" \
  '{host:{product_version:$product,build_version:$build,architecture:$arch,kernel_release:$kernel},managers:{homebrew:{path:$brew_path,prefix:$brew_prefix,version:$brew_version},macports:{available:($port_path|length>0),path:(if ($port_path|length)>0 then $port_path else null end),prefix:(if ($port_path|length)>0 then "/opt/local" else null end),version:(if ($port_version|length)>0 then $port_version else null end)}}}')"
ownership_body="$($jq_bin -cn --argjson formulae "$normalized_formulae" --argjson casks "$normalized_casks" '{formulae:$formulae,cask_formula_requirements:[$casks[]|{token,formula_requirements}]}')"
environment_digest="$(print -rn -- "$environment_body" | $jq_bin -cS . | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
ownership_digest="$(print -rn -- "$ownership_body" | $jq_bin -cS . | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
evidence_body="$($jq_bin -cn --arg environment "$environment_digest" --arg ownership "$ownership_digest" --argjson scope "$scope_json" '{environment_digest:$environment,ownership_digest:$ownership,scope:$scope}')"
evidence_digest="$(print -rn -- "$evidence_body" | $jq_bin -cS . | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

typeset hard_blocks warnings
hard_blocks='[]'
warnings='[]'
[[ "$architecture" == x86_64 ]] || hard_blocks="$($jq_bin -n --arg arch "$architecture" '[{code:"unsupported_architecture",detail:("expected x86_64, found " + $arch)}]')"
if [[ -z "$port_bin" ]]; then
  warnings='[{"code":"macports_unavailable","detail":"MacPorts candidate verification is unavailable until MacPorts is installed at /opt/local."}]'
fi

$jq_bin -n \
  --argjson schema_version 2 \
  --arg recorded_utc "$recorded_utc" --arg recorded_local "$recorded_local" \
  --argjson environment "$environment_body" --argjson scope "$scope_json" \
  --argjson formulae "$normalized_formulae" --argjson casks "$normalized_casks" \
  --arg environment_digest "$environment_digest" --arg ownership_digest "$ownership_digest" --arg evidence_digest "$evidence_digest" \
  --argjson warnings "$warnings" --argjson hard_blocks "$hard_blocks" \
  '{schema_version:$schema_version,recorded_at:{utc:$recorded_utc,local:$recorded_local},host:$environment.host,managers:$environment.managers,scope:$scope,formulae:$formulae,casks:$casks,digests:{environment:$environment_digest,ownership:$ownership_digest,evidence:$evidence_digest},warnings:$warnings,hard_blocks:$hard_blocks,mutations_performed:false}'
