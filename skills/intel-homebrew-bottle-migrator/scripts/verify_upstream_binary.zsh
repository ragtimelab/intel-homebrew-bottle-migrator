#!/bin/zsh

set -eu
setopt pipefail no_unset extendedglob
umask 077
export LC_ALL=C

usage() { print -u2 'usage: verify_upstream_binary.zsh --file ABSOLUTE_PATH --expected-sha256 SHA256'; }

typeset binary_file='' expected_sha=''
while (( $# > 0 )); do
  case "$1" in
    --file) (( $# >= 2 )) || { usage; exit 2; }; binary_file="$2"; shift 2 ;;
    --expected-sha256) (( $# >= 2 )) || { usage; exit 2; }; expected_sha="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$binary_file" == /* && -f "$binary_file" && ! -L "$binary_file" ]] || { print -u2 'binary must be an absolute, non-symlink regular file'; exit 2; }
[[ "$expected_sha" == [0-9A-Fa-f]## && ${#expected_sha} == 64 ]] || { print -u2 'expected SHA-256 must contain 64 hexadecimal characters'; exit 2; }

typeset jq_bin
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
else
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
fi
[[ -n "${jq_bin:-}" && -x "$jq_bin" ]] || { print -u2 'trusted jq executable not found'; exit 2; }

typeset actual_sha file_output architectures='' links='' foreign_links='' codesign_output='' gatekeeper_output=''
typeset codesign_valid=false gatekeeper_accepted=false
actual_sha="$(/usr/bin/shasum -a 256 "$binary_file" | /usr/bin/awk '{print $1}')"
file_output="$(/usr/bin/file "$binary_file")"
if /usr/bin/lipo -archs "$binary_file" >/dev/null 2>&1; then
  architectures="$(/usr/bin/lipo -archs "$binary_file" 2>/dev/null)"
elif [[ "$file_output" == *x86_64* ]]; then
  architectures=x86_64
fi
if [[ "$file_output" == *Mach-O* ]]; then
  links="$(/usr/bin/otool -L "$binary_file" 2>/dev/null | /usr/bin/sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p')"
  foreign_links="$(print -r -- "$links" | /usr/bin/grep -E '^(/usr/local|/opt/local)/' || true)"
  if codesign_output="$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$binary_file" 2>&1)"; then
    codesign_valid=true
  fi
  if gatekeeper_output="$(/usr/sbin/spctl --assess --type execute --verbose=2 "$binary_file" 2>&1)"; then
    gatekeeper_accepted=true
  fi
fi

typeset hard_blocks warnings
hard_blocks='[]'
warnings='[]'
if [[ "$actual_sha" != "${expected_sha:l}" ]]; then
  hard_blocks="$($jq_bin -n '[{code:"sha256_mismatch"}]')"
elif [[ " $architectures " != *' x86_64 '* ]]; then
  hard_blocks="$($jq_bin -n --arg architectures "$architectures" '[{code:"architecture_mismatch",detail:$architectures}]')"
elif [[ -n "$foreign_links" ]]; then
  hard_blocks="$($jq_bin -n --arg links "$foreign_links" '[{code:"foreign_package_manager_linkage",detail:$links}]')"
fi
if [[ "$codesign_valid" != true ]]; then
  warnings='[{"code":"codesign_not_verified","detail":"Publisher provenance or an independent signature must be reviewed by the LLM."}]'
fi

$jq_bin -n \
  --arg recorded_utc "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg recorded_local "$(/bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)')" \
  --arg path "$binary_file" --arg expected_sha256 "${expected_sha:l}" --arg actual_sha256 "$actual_sha" \
  --arg file_output "$file_output" \
  --argjson architectures "$(print -r -- "$architectures" | $jq_bin -R -s 'split(" ")|map(select(length>0))')" \
  --argjson dynamic_links "$(print -r -- "$links" | $jq_bin -R -s 'split("\n")|map(select(length>0))')" \
  --argjson foreign_links "$(print -r -- "$foreign_links" | $jq_bin -R -s 'split("\n")|map(select(length>0))')" \
  --argjson codesign_valid "$codesign_valid" --arg codesign_output "$codesign_output" \
  --argjson gatekeeper_accepted "$gatekeeper_accepted" --arg gatekeeper_output "$gatekeeper_output" \
  --argjson warnings "$warnings" --argjson hard_blocks "$hard_blocks" \
  '{schema_version:2,recorded_at:{utc:$recorded_utc,local:$recorded_local},artifact:{path:$path,expected_sha256:$expected_sha256,actual_sha256:$actual_sha256,digest_matches:($expected_sha256==$actual_sha256),file_output:$file_output,architectures:$architectures,dynamic_links:$dynamic_links,foreign_package_manager_links:$foreign_links,codesign:{verified:$codesign_valid,output:$codesign_output},gatekeeper:{accepted:$gatekeeper_accepted,output:$gatekeeper_output}},binary_executed:false,publisher_provenance_verified:false,warnings:$warnings,hard_blocks:$hard_blocks,mutations_performed:false}'
