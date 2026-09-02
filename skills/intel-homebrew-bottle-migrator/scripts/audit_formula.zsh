#!/bin/zsh

set -u
setopt extendedglob
umask 077
export LC_ALL=C
export HOMEBREW_NO_AUTO_UPDATE=1

readonly capture_limit=32768
typeset capture_dir=''
typeset -i capture_sequence=0
typeset -i CAPTURE_EXIT=0
typeset CAPTURE_STDOUT=''
typeset CAPTURE_STDERR=''
typeset CAPTURE_TRUNCATED=false
typeset -a errors warnings hard_blocks

usage() {
  print -u2 'usage: audit_formula.zsh [--port PORT] [--variant +NAME|-NAME]... [--command COMMAND]... [--command-path COMMAND=PREFIX_RELATIVE_PATH]... FORMULA'
}

json_error() {
  local message="$1"
  local code="$2"
  jq -n --arg error "$message" --argjson exit_code "$code" \
    '{error: $error, exit_code: $exit_code}'
  exit "$code"
}

cleanup() {
  [[ -n "$capture_dir" && -d "$capture_dir" ]] && rm -rf -- "$capture_dir"
}

run_capture() {
  capture_sequence=$((capture_sequence + 1))
  local stdout_path="$capture_dir/$capture_sequence.stdout"
  local stderr_path="$capture_dir/$capture_sequence.stderr"
  "$@" >"$stdout_path" 2>"$stderr_path"
  CAPTURE_EXIT=$?
  CAPTURE_STDOUT="$(<"$stdout_path")"
  CAPTURE_STDERR="$(<"$stderr_path")"
  CAPTURE_TRUNCATED=false
  if (( ${#CAPTURE_STDOUT} > capture_limit )); then
    CAPTURE_STDOUT="${CAPTURE_STDOUT[1,capture_limit]}"
    CAPTURE_TRUNCATED=true
  fi
  if (( ${#CAPTURE_STDERR} > capture_limit )); then
    CAPTURE_STDERR="${CAPTURE_STDERR[1,capture_limit]}"
    CAPTURE_TRUNCATED=true
  fi
}

capture_json() {
  local state="$1"
  jq -n \
    --arg state "$state" \
    --argjson exit_code "$CAPTURE_EXIT" \
    --arg stdout "$CAPTURE_STDOUT" \
    --arg stderr "$CAPTURE_STDERR" \
    --argjson truncated "$CAPTURE_TRUNCATED" \
    '{state:$state,exit_code:$exit_code,stdout:$stdout,stderr:$stderr,truncated:$truncated}'
}

not_applicable_json() {
  jq -n '{state:"not_applicable",exit_code:0,stdout:"",stderr:"",truncated:false}'
}

lines_json() {
  print -rn -- "$1" | jq -R -s 'split("\n") | map(select(length > 0)) | unique'
}

strings_json() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0)) | unique'
  fi
}

items_json() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -s '.'
  fi
}

add_error() {
  errors+=("$(jq -n --arg stage "$1" --argjson exit_code "$2" --arg stderr "$3" \
    '{stage:$stage,exit_code:$exit_code,stderr:$stderr}')")
}

add_warning() {
  warnings+=("$(jq -n --arg code "$1" --arg detail "$2" '{code:$code,detail:$detail}')")
}

add_hard_block() {
  hard_blocks+=("$(jq -n --arg code "$1" --arg detail "$2" '{code:$code,detail:$detail}')")
}

version_relation() {
  local candidate normalized_candidate baseline normalized_baseline
  candidate="$1"
  baseline="$2"
  if [[ "$candidate" == "$baseline" ]]; then
    print -r -- equal
    return
  fi
  if ! print -r -- "$candidate" | grep -Eq '^v?[0-9]+([.][0-9]+)*$' || \
     ! print -r -- "$baseline" | grep -Eq '^v?[0-9]+([.][0-9]+)*$'; then
    print -r -- unknown
    return
  fi
  normalized_candidate="${candidate#v}"
  normalized_baseline="${baseline#v}"
  awk -v candidate="$normalized_candidate" -v baseline="$normalized_baseline" '
    BEGIN {
      nc=split(candidate,c,"."); nb=split(baseline,b,"."); n=(nc>nb?nc:nb)
      for (i=1;i<=n;i++) {
        cv=(i<=nc?c[i]+0:0); bv=(i<=nb?b[i]+0:0)
        if (cv < bv) { print "lower"; exit }
        if (cv > bv) { print "higher"; exit }
      }
      print "equal"
    }'
}

typeset candidate_port=''
typeset -a candidate_variants command_names
typeset -A command_relative_paths

while (( $# > 0 )); do
  case "$1" in
    --port)
      (( $# >= 2 )) || { usage; exit 2; }
      candidate_port="$2"
      shift 2
      ;;
    --variant)
      (( $# >= 2 )) || { usage; exit 2; }
      candidate_variants+=("$2")
      shift 2
      ;;
    --command)
      (( $# >= 2 )) || { usage; exit 2; }
      command_names+=("$2")
      shift 2
      ;;
    --command-path)
      (( $# >= 2 )) || { usage; exit 2; }
      typeset command_path_spec="$2"
      typeset command_path_name="${command_path_spec%%=*}"
      typeset command_relative_path="${command_path_spec#*=}"
      [[ "$command_path_spec" == *=* && -n "$command_path_name" && -n "$command_relative_path" ]] || {
        json_error "invalid command path: $command_path_spec" 2
      }
      command_names+=("$command_path_name")
      command_relative_paths[$command_path_name]="$command_relative_path"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

(( $# == 1 )) || { usage; exit 2; }
typeset formula_name="$1"
[[ "$formula_name" == [A-Za-z0-9._+@/-]## ]] || json_error 'invalid formula name' 2
[[ -z "$candidate_port" || "$candidate_port" == [A-Za-z0-9._+-]## ]] || json_error 'invalid port name' 2
for command_name in "${command_names[@]}"; do
  [[ "$command_name" == [A-Za-z0-9._+-]## ]] || json_error "invalid command name: $command_name" 2
  if [[ -n "${command_relative_paths[$command_name]:-}" ]]; then
    typeset relative_path="${command_relative_paths[$command_name]}"
    [[ "$relative_path" != /* && "$relative_path" != *'//'*
       && "$relative_path" != '.' && "$relative_path" != '..'
       && "$relative_path" != './'* && "$relative_path" != '../'*
       && "$relative_path" != *'/./'* && "$relative_path" != *'/../'*
       && "$relative_path" != *'/.' && "$relative_path" != *'/..'
       && "$relative_path" == [A-Za-z0-9._+@/-]## ]] || \
      json_error "invalid prefix-relative command path: $relative_path" 2
  fi
done

typeset brew_bin jq_bin port_bin file_bin otool_bin login_shell
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  brew_bin="${IHBM_BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  port_bin="${IHBM_PORT_BIN:-$(command -v port 2>/dev/null || true)}"
  file_bin="${IHBM_FILE_BIN:-$(command -v file 2>/dev/null || true)}"
  otool_bin="${IHBM_OTOOL_BIN:-$(command -v otool 2>/dev/null || true)}"
  login_shell="${IHBM_LOGIN_SHELL:-/bin/zsh}"
else
  brew_bin=/usr/local/bin/brew
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
  [[ -x /opt/local/bin/port ]] && port_bin=/opt/local/bin/port
  file_bin=/usr/bin/file
  otool_bin=/usr/bin/otool
  login_shell=/bin/zsh
fi
[[ -n "$jq_bin" ]] || { print -u2 'jq is required'; exit 2; }
[[ -n "$brew_bin" ]] || json_error 'Homebrew is not available' 3
[[ -x "$login_shell" ]] || json_error "login shell is not executable: $login_shell" 2

capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/ihbm-audit.XXXXXX")" || json_error 'cannot create temporary directory' 3
trap cleanup EXIT INT TERM

typeset recorded_utc recorded_local product_version build_version architecture brew_version brew_prefix macports_prefix
recorded_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
recorded_local="$(/bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
product_version="$(/usr/bin/sw_vers -productVersion)"
build_version="$(/usr/bin/sw_vers -buildVersion)"
architecture="$(/usr/bin/uname -m)"
brew_version="$($brew_bin --version | sed -n '1s/^Homebrew //p')"
brew_prefix="$($brew_bin --prefix)"
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  macports_prefix="${IHBM_MACPORTS_PREFIX:-/opt/local}"
else
  macports_prefix=/opt/local
fi
[[ "$architecture" == x86_64 ]] || add_hard_block 'unsupported_architecture' "expected x86_64, found $architecture"

typeset formula_info_stderr="$capture_dir/formula-info.stderr"
typeset formula_json
formula_json="$($brew_bin info --json=v2 "$formula_name" 2>"$formula_info_stderr")"
typeset -i formula_info_exit=$?
(( formula_info_exit == 0 )) || json_error "unknown or unavailable Homebrew formula: $formula_name" 3
print -rn -- "$formula_json" | "$jq_bin" -e . >/dev/null 2>&1 || json_error 'Homebrew formula JSON is invalid' 3

typeset -i formula_count cask_count installed_count
formula_count="$(print -rn -- "$formula_json" | "$jq_bin" '.formulae | length')"
cask_count="$(print -rn -- "$formula_json" | "$jq_bin" '.casks | length')"
if (( formula_count == 0 )); then
  (( cask_count > 0 )) && json_error "$formula_name is a Homebrew cask and is outside this skill" 4
  json_error "unknown or unavailable Homebrew formula: $formula_name" 3
fi

typeset canonical_formula homebrew_catalog_version homebrew_linked_keg installed_receipts installed_on_request poured_from_bottle bottle_tags
canonical_formula="$(print -rn -- "$formula_json" | "$jq_bin" -r '.formulae[0].full_name // .formulae[0].name')"
homebrew_catalog_version="$(print -rn -- "$formula_json" | "$jq_bin" -r '.formulae[0].versions.stable // ""')"
homebrew_linked_keg="$(print -rn -- "$formula_json" | "$jq_bin" -r '.formulae[0].linked_keg // ""')"
installed_receipts="$(print -rn -- "$formula_json" | "$jq_bin" '.formulae[0].installed // []')"
installed_count="$(print -rn -- "$installed_receipts" | "$jq_bin" 'length')"
installed_on_request="$(print -rn -- "$installed_receipts" | "$jq_bin" '[.[]?.installed_on_request == true] | any')"
poured_from_bottle="$(print -rn -- "$installed_receipts" | "$jq_bin" '[.[]?.poured_from_bottle]')"
bottle_tags="$(print -rn -- "$formula_json" | "$jq_bin" '[(.formulae[0].bottle.stable.files // {}) | keys[]]')"

typeset direct_reverse recursive_reverse direct_reverse_json recursive_reverse_json
run_capture "$brew_bin" uses --installed "$canonical_formula"
if (( CAPTURE_EXIT == 0 )); then
  direct_reverse="$CAPTURE_STDOUT"
else
  direct_reverse=''
  add_error 'brew_uses_direct' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
fi
direct_reverse_json="$(lines_json "$direct_reverse")"

run_capture "$brew_bin" uses --installed --recursive "$canonical_formula"
if (( CAPTURE_EXIT == 0 )); then
  recursive_reverse="$CAPTURE_STDOUT"
else
  recursive_reverse=''
  add_error 'brew_uses_recursive' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
fi
recursive_reverse_json="$(lines_json "$recursive_reverse")"

typeset upgrade_plan_json brew_list_output=''
if (( installed_count > 0 )); then
  run_capture "$brew_bin" upgrade --formula --dry-run "$canonical_formula"
  if (( CAPTURE_EXIT == 0 )); then
    upgrade_plan_json="$(capture_json completed)"
  else
    upgrade_plan_json="$(capture_json failed)"
    add_error 'brew_upgrade_dry_run' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
  fi
  run_capture "$brew_bin" list "$canonical_formula"
  if (( CAPTURE_EXIT == 0 )); then
    brew_list_output="$CAPTURE_STDOUT"
  else
    add_error 'brew_list_formula' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
  fi
else
  upgrade_plan_json="$(not_applicable_json)"
fi

typeset macports_available=false macports_version=''
typeset candidate_catalog_version='' candidate_active=false candidate_installed_receipt=''
typeset candidate_requested=false available_variants_output='' port_contents_output=''
typeset local_archives_json='[]' binary_plan_json remote_archive_verified=false
typeset -a local_archives port_spec
binary_plan_json="$(not_applicable_json)"

if [[ -n "$port_bin" ]]; then
  macports_available=true
  run_capture "$port_bin" version
  if (( CAPTURE_EXIT == 0 )); then
    macports_version="$(print -r -- "$CAPTURE_STDOUT" | sed -n 's/^Version: //p')"
  else
    add_error 'port_version' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
  fi
fi

if [[ -n "$candidate_port" ]]; then
  if [[ "$macports_available" != true ]]; then
    add_hard_block 'macports_unavailable' 'MacPorts is not available on PATH'
  else
    port_spec=("$candidate_port" "${candidate_variants[@]}")
    run_capture "$port_bin" info --version --line "$candidate_port"
    if (( CAPTURE_EXIT == 0 )); then
      candidate_catalog_version="$(print -r -- "$CAPTURE_STDOUT" | sed -n '1p')"
    else
      add_error 'port_info_version' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
    fi

    run_capture "$port_bin" variants "$candidate_port"
    if (( CAPTURE_EXIT == 0 )); then
      available_variants_output="$CAPTURE_STDOUT"
    else
      add_error 'port_variants' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
    fi

    run_capture "$port_bin" installed "$candidate_port"
    if (( CAPTURE_EXIT == 0 )); then
      candidate_installed_receipt="$(print -r -- "$CAPTURE_STDOUT" | sed -n '/^[[:space:]]*[^[:space:]].*(active)/p' | sed 's/^[[:space:]]*//')"
      [[ -n "$candidate_installed_receipt" ]] && candidate_active=true
    else
      add_error 'port_installed_candidate' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
    fi

    run_capture "$port_bin" echo requested
    if (( CAPTURE_EXIT == 0 )); then
      if print -r -- "$CAPTURE_STDOUT" | awk -v name="$candidate_port" '$1 == name {found=1} END {exit !found}'; then
        candidate_requested=true
      fi
    else
      add_error 'port_requested' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
    fi

    if [[ "$candidate_active" == true ]]; then
      run_capture "$port_bin" contents "$candidate_port"
      if (( CAPTURE_EXIT == 0 )); then
        port_contents_output="$CAPTURE_STDOUT"
      else
        add_error 'port_contents' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
      fi
      local_archives=($macports_prefix/var/macports/software/$candidate_port/*.tbz2(N))
      local_archives_json="$(strings_json "${local_archives[@]}")"
    fi

    if [[ "$candidate_active" == true ]]; then
      binary_plan_json="$(jq -n '{state:"not_applicable",exit_code:0,stdout:"candidate already active; no binary-only install plan was executed",stderr:"",truncated:false}')"
    else
      run_capture "$port_bin" -b -y install "${port_spec[@]}"
      if (( CAPTURE_EXIT == 0 )); then
        binary_plan_json="$(capture_json completed)"
      else
        binary_plan_json="$(capture_json failed)"
        add_hard_block 'binary_only_plan_failed' "port -b -y install failed for $candidate_port"
        add_error 'port_binary_only_plan' "$CAPTURE_EXIT" "$CAPTURE_STDERR"
      fi
    fi
  fi
fi

if (( ${#command_names} == 0 )); then
  typeset path_line
  for path_line in ${(f)brew_list_output}; do
    case "$path_line" in
      */bin/*|*/sbin/*)
        [[ -x "$path_line" ]] && command_names+=("${path_line:t}")
        ;;
    esac
  done
  for path_line in ${(f)port_contents_output}; do
    path_line="${path_line##[[:space:]]#}"
    case "$path_line" in
      */bin/*|*/sbin/*) command_names+=("${path_line:t}") ;;
    esac
  done
fi
command_names=("${(@u)command_names}")

typeset -a command_items
typeset command_name='' path_line='' current_shell_path='' fresh_login_path='' prefix_link='' prefix_link_target=''
for command_name in "${command_names[@]}"; do
  typeset -a keg_paths=() candidate_paths=() candidate_binary_items=()
  typeset candidate_relative_path="${command_relative_paths[$command_name]:-}"
  prefix_link=''
  prefix_link_target=''

  for path_line in ${(f)brew_list_output}; do
    [[ "${path_line:t}" == "$command_name" ]] || continue
    case "$path_line" in
      */bin/*|*/sbin/*) [[ -x "$path_line" ]] && keg_paths+=("$path_line") ;;
    esac
  done

  for path_line in "$brew_prefix/bin/$command_name" "$brew_prefix/sbin/$command_name"; do
    if [[ -e "$path_line" || -L "$path_line" ]]; then
      prefix_link="$path_line"
      [[ -L "$path_line" ]] && prefix_link_target="$(readlink "$path_line")"
      break
    fi
  done

  current_shell_path="$(whence -p -- "$command_name" 2>/dev/null || true)"
  run_capture "$login_shell" -lic 'resolved=$(whence -p -- "$1" 2>/dev/null || true); print -r -- "__IHBM_PATH__${resolved}"' ihbm "$command_name"
  fresh_login_path="$(print -r -- "$CAPTURE_STDOUT" | sed -n 's/^__IHBM_PATH__//p' | tail -n 1)"
  (( CAPTURE_EXIT == 0 )) || add_error "fresh_login_path:$command_name" "$CAPTURE_EXIT" "$CAPTURE_STDERR"

  if [[ -n "$candidate_relative_path" ]]; then
    typeset intended_candidate_path="$macports_prefix/$candidate_relative_path"
    if [[ -e "$intended_candidate_path" || -L "$intended_candidate_path" ]]; then
      candidate_paths+=("$intended_candidate_path")
    elif [[ "$candidate_active" == true ]]; then
      add_hard_block 'candidate_command_missing' "$intended_candidate_path is absent from active $candidate_port"
    fi
  else
    for path_line in ${(f)port_contents_output}; do
      path_line="${path_line##[[:space:]]#}"
      [[ "${path_line:t}" == "$command_name" ]] || continue
      case "$path_line" in
        */bin/*|*/sbin/*) candidate_paths+=("$path_line") ;;
      esac
    done
  fi
  candidate_paths=("${(@u)candidate_paths}")

  typeset candidate_path='' file_output=''
  for candidate_path in "${candidate_paths[@]}"; do
    typeset architectures_json='[]' dynamic_links_json='[]' cross_links_json='[]' self_version_json
    typeset dynamic_output='' cross_output=''
    if [[ -n "$file_bin" ]]; then
      run_capture "$file_bin" "$candidate_path"
      if (( CAPTURE_EXIT == 0 )); then
        file_output="$CAPTURE_STDOUT"
        architectures_json="$(print -r -- "$file_output" | grep -Eo 'x86_64|arm64' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"
        if [[ "$architecture" == x86_64 ]] && ! print -r -- "$file_output" | grep -q 'x86_64'; then
          add_hard_block 'candidate_architecture_mismatch' "$candidate_path is not x86_64"
        fi
      else
        add_error "file:$candidate_path" "$CAPTURE_EXIT" "$CAPTURE_STDERR"
      fi
    else
      add_error 'file_tool' 127 'file command is unavailable'
    fi

    if [[ -n "$otool_bin" ]] && print -r -- "$file_output" | grep -q 'Mach-O'; then
      run_capture "$otool_bin" -L "$candidate_path"
      if (( CAPTURE_EXIT == 0 )); then
        dynamic_output="$(print -r -- "$CAPTURE_STDOUT" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p')"
        dynamic_links_json="$(lines_json "$dynamic_output")"
        if [[ "$candidate_path" == $macports_prefix/* ]]; then
          cross_output="$(print -r -- "$dynamic_output" | grep "^$brew_prefix/" || true)"
        elif [[ "$candidate_path" == $brew_prefix/* ]]; then
          cross_output="$(print -r -- "$dynamic_output" | grep "^$macports_prefix/" || true)"
        fi
        cross_links_json="$(lines_json "$cross_output")"
        [[ -z "$cross_output" ]] || add_hard_block 'cross_prefix_linkage' "$candidate_path links across package-manager prefixes"
      else
        add_error "otool:$candidate_path" "$CAPTURE_EXIT" "$CAPTURE_STDERR"
      fi
    fi

    if [[ -x "$candidate_path" ]]; then
      run_capture "$candidate_path" --version
      if (( CAPTURE_EXIT == 0 )); then
        self_version_json="$(capture_json completed)"
      else
        self_version_json="$(capture_json failed)"
        add_warning 'self_version_probe_failed' "$candidate_path --version exited $CAPTURE_EXIT"
      fi
    else
      self_version_json="$(not_applicable_json)"
      add_warning 'candidate_not_executable' "$candidate_path is not executable or is absent"
    fi

    candidate_binary_items+=("$(jq -n \
      --arg path "$candidate_path" \
      --arg file_output "$file_output" \
      --argjson architectures "$architectures_json" \
      --argjson dynamic_links "$dynamic_links_json" \
      --argjson cross_prefix_links "$cross_links_json" \
      --argjson self_reported_version "$self_version_json" \
      '{path:$path,file_output:$file_output,architectures:$architectures,dynamic_links:$dynamic_links,cross_prefix_links:$cross_prefix_links,self_reported_version:$self_reported_version}')")
  done

  typeset keg_paths_json='' candidate_binaries_json=''
  keg_paths_json="$(strings_json "${keg_paths[@]}")"
  candidate_binaries_json="$(items_json "${candidate_binary_items[@]}")"
  command_items+=("$(jq -n \
    --arg name "$command_name" \
    --arg candidate_relative_path "$candidate_relative_path" \
    --argjson homebrew_keg_paths "$keg_paths_json" \
    --arg homebrew_prefix_link "$prefix_link" \
    --arg homebrew_link_target "$prefix_link_target" \
    --arg current_shell_path "$current_shell_path" \
    --arg fresh_login_shell_path "$fresh_login_path" \
    --argjson candidate_binaries "$candidate_binaries_json" \
    '{name:$name,candidate_relative_path:(if ($candidate_relative_path|length)>0 then $candidate_relative_path else null end),homebrew_keg_paths:$homebrew_keg_paths,homebrew_prefix_link:(if ($homebrew_prefix_link|length)>0 then $homebrew_prefix_link else null end),homebrew_link_target:(if ($homebrew_link_target|length)>0 then $homebrew_link_target else null end),current_shell_path:(if ($current_shell_path|length)>0 then $current_shell_path else null end),fresh_login_shell_path:(if ($fresh_login_shell_path|length)>0 then $fresh_login_shell_path else null end),candidate_binaries:$candidate_binaries}')")
done

typeset active_owner='' active_version='' active_evidence=''
if [[ -n "$homebrew_linked_keg" ]]; then
  active_owner='homebrew'
  active_version="$homebrew_linked_keg"
  active_evidence='homebrew_linked_keg'
elif (( installed_count > 0 )); then
  active_owner='homebrew'
  active_version="$(print -rn -- "$installed_receipts" | "$jq_bin" -r 'last.version // ""')"
  active_evidence='homebrew_installed_receipt'
elif [[ "$candidate_active" == true && -n "$candidate_installed_receipt" ]]; then
  active_owner='macports'
  active_version="$(print -r -- "$candidate_installed_receipt" | sed -E 's/^[^@]*@([^_+[:space:]]+).*/\1/')"
  active_evidence='macports_active_receipt'
fi

typeset current_owner='' fresh_owner='' command_current_owner='' command_fresh_owner=''
for command_item in "${command_items[@]}"; do
  current_shell_path="$(print -r -- "$command_item" | "$jq_bin" -r '.current_shell_path // ""')"
  fresh_login_path="$(print -r -- "$command_item" | "$jq_bin" -r '.fresh_login_shell_path // ""')"
  command_current_owner=''
  command_fresh_owner=''
  [[ "$current_shell_path" == "$brew_prefix"/* ]] && command_current_owner='homebrew'
  [[ "$current_shell_path" == "$macports_prefix"/* ]] && command_current_owner='macports'
  [[ "$fresh_login_path" == "$brew_prefix"/* ]] && command_fresh_owner='homebrew'
  [[ "$fresh_login_path" == "$macports_prefix"/* ]] && command_fresh_owner='macports'
  if [[ -n "$command_current_owner" && -n "$command_fresh_owner" && "$command_current_owner" != "$command_fresh_owner" ]]; then
    add_hard_block 'ownership_baseline_ambiguous' "current and fresh-login owners differ for a command: $command_current_owner vs $command_fresh_owner"
  fi
  [[ -n "$command_current_owner" ]] && current_owner="$command_current_owner"
  [[ -n "$command_fresh_owner" ]] && fresh_owner="$command_fresh_owner"
done

typeset resolved_owner="$current_owner"
[[ -n "$fresh_owner" ]] && resolved_owner="$fresh_owner"
if [[ "$resolved_owner" == macports && "$candidate_active" == true ]]; then
  active_owner='macports'
  active_version="$(print -r -- "$candidate_installed_receipt" | sed -E 's/^[^@]*@([^_+[:space:]]+).*/\1/')"
  active_evidence='resolved_path_and_macports_active_receipt'
elif [[ "$resolved_owner" == homebrew && $installed_count -gt 0 ]]; then
  active_owner='homebrew'
  active_version="${homebrew_linked_keg:-$(print -rn -- "$installed_receipts" | "$jq_bin" -r 'last.version // ""')}"
  active_evidence='resolved_path_and_homebrew_receipt'
fi

typeset candidate_vs_active='unknown' candidate_vs_homebrew_catalog='unknown'
typeset ownership_transition_is_downgrade='null' catalog_lag_detected='null' security_review_required=false
if [[ -n "$candidate_catalog_version" && -n "$active_version" ]]; then
  candidate_vs_active="$(version_relation "$candidate_catalog_version" "$active_version")"
  if [[ "$candidate_vs_active" == lower ]]; then
    ownership_transition_is_downgrade=true
    security_review_required=true
    add_warning 'downgrade_requires_security_review' "$active_version -> $candidate_catalog_version requires security and compatibility review"
  elif [[ "$candidate_vs_active" == equal || "$candidate_vs_active" == higher ]]; then
    ownership_transition_is_downgrade=false
  else
    add_warning 'active_version_comparison_unknown' "cannot compare $active_version with $candidate_catalog_version without guessing"
  fi
fi
if [[ -n "$candidate_catalog_version" && -n "$homebrew_catalog_version" ]]; then
  candidate_vs_homebrew_catalog="$(version_relation "$candidate_catalog_version" "$homebrew_catalog_version")"
  if [[ "$candidate_vs_homebrew_catalog" == lower ]]; then
    catalog_lag_detected=true
    add_warning 'catalog_lag_detected' "MacPorts $candidate_catalog_version trails Homebrew catalog $homebrew_catalog_version; this is not an ownership downgrade"
  elif [[ "$candidate_vs_homebrew_catalog" == equal || "$candidate_vs_homebrew_catalog" == higher ]]; then
    catalog_lag_detected=false
  else
    add_warning 'catalog_version_comparison_unknown' "cannot compare $candidate_catalog_version with $homebrew_catalog_version without guessing"
  fi
fi

typeset variants_json available_variants_json commands_json errors_json warnings_json hard_blocks_json
variants_json="$(strings_json "${candidate_variants[@]}")"
available_variants_json="$(lines_json "$available_variants_output")"
commands_json="$(items_json "${command_items[@]}")"
errors_json="$(items_json "${errors[@]}")"
warnings_json="$(items_json "${warnings[@]}")"
hard_blocks_json="$(items_json "${hard_blocks[@]}")"

"$jq_bin" -n \
  --argjson schema_version 4 \
  --arg recorded_utc "$recorded_utc" \
  --arg recorded_local "$recorded_local" \
  --arg product_version "$product_version" \
  --arg build_version "$build_version" \
  --arg architecture "$architecture" \
  --arg brew_version "$brew_version" \
  --arg brew_prefix "$brew_prefix" \
  --arg macports_prefix "$macports_prefix" \
  --arg formula_name "$canonical_formula" \
  --arg homebrew_catalog_version "$homebrew_catalog_version" \
  --arg homebrew_linked_keg "$homebrew_linked_keg" \
  --argjson installed_receipts "$installed_receipts" \
  --argjson installed_on_request "$installed_on_request" \
  --argjson poured_from_bottle "$poured_from_bottle" \
  --argjson bottle_tags "$bottle_tags" \
  --argjson upgrade_plan "$upgrade_plan_json" \
  --argjson direct_reverse "$direct_reverse_json" \
  --argjson recursive_reverse "$recursive_reverse_json" \
  --argjson manager_available "$macports_available" \
  --arg manager_version "$macports_version" \
  --arg candidate_name "$candidate_port" \
  --argjson requested_variants "$variants_json" \
  --argjson available_variants "$available_variants_json" \
  --arg catalog_version "$candidate_catalog_version" \
  --argjson candidate_active "$candidate_active" \
  --arg installed_receipt "$candidate_installed_receipt" \
  --argjson requested_root "$candidate_requested" \
  --argjson local_archives "$local_archives_json" \
  --argjson binary_plan "$binary_plan_json" \
  --argjson remote_archive_verified "$remote_archive_verified" \
  --argjson commands "$commands_json" \
  --arg active_owner "$active_owner" \
  --arg active_version "$active_version" \
  --arg active_evidence "$active_evidence" \
  --arg candidate_vs_active "$candidate_vs_active" \
  --arg candidate_vs_homebrew_catalog "$candidate_vs_homebrew_catalog" \
  --argjson ownership_transition_is_downgrade "$ownership_transition_is_downgrade" \
  --argjson catalog_lag_detected "$catalog_lag_detected" \
  --argjson security_review_required "$security_review_required" \
  --argjson hard_blocks "$hard_blocks_json" \
  --argjson warnings "$warnings_json" \
  --argjson errors "$errors_json" \
  '{
    schema_version:$schema_version,
    recorded_at:{utc:$recorded_utc,local:$recorded_local},
    host:{product_version:$product_version,build_version:$build_version,architecture:$architecture},
    homebrew:{
      manager_version:$brew_version,
      prefix:$brew_prefix,
      formula:{name:$formula_name,catalog_version:$homebrew_catalog_version,linked_keg:(if ($homebrew_linked_keg|length)>0 then $homebrew_linked_keg else null end),installed_receipts:$installed_receipts,installed_on_request:$installed_on_request,poured_from_bottle:$poured_from_bottle,bottle_tags:$bottle_tags,upgrade_plan:$upgrade_plan},
      reverse_dependencies:{direct:$direct_reverse,recursive:$recursive_reverse}
    },
    macports:{
      manager_available:$manager_available,
      manager_version:$manager_version,
      prefix:$macports_prefix,
      candidate:{name:$candidate_name,requested_variants:$requested_variants,available_variants:$available_variants,catalog_version:$catalog_version,active:$candidate_active,installed_receipt:$installed_receipt,requested_root:$requested_root,local_rollback_archives:$local_archives,binary_only_plan:$binary_plan,remote_archive_verified:$remote_archive_verified}
    },
    commands:$commands,
    version_relation:{
      active_baseline:{owner:(if ($active_owner|length)>0 then $active_owner else null end),version:(if ($active_version|length)>0 then $active_version else null end),evidence:(if ($active_evidence|length)>0 then $active_evidence else null end)},
      macports_candidate_version:(if ($catalog_version|length)>0 then $catalog_version else null end),
      homebrew_catalog_version:(if ($homebrew_catalog_version|length)>0 then $homebrew_catalog_version else null end),
      candidate_vs_active:$candidate_vs_active,
      candidate_vs_homebrew_catalog:$candidate_vs_homebrew_catalog,
      ownership_transition_is_downgrade:$ownership_transition_is_downgrade,
      catalog_lag_detected:$catalog_lag_detected,
      security_review_required:$security_review_required
    },
    hard_blocks:$hard_blocks,
    warnings:$warnings,
    errors:$errors
  }'
