#!/bin/zsh

set -u
setopt extendedglob pipefail
umask 077
export LC_ALL=C

typeset -a requested_variants command_names errors warnings hard_blocks command_items
typeset -A command_relative_paths
typeset temp_dir=''

usage() {
  print -u2 'usage: verify_port_archive.zsh [--variant +NAME|-NAME]... [--command COMMAND]... [--command-path COMMAND=PREFIX_RELATIVE_PATH]... PORT'
}

cleanup() {
  [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
}

add_error() {
  errors+=("$(jq -n --arg stage "$1" --arg detail "$2" '{stage:$stage,detail:$detail}')")
}

add_warning() {
  warnings+=("$(jq -n --arg code "$1" --arg detail "$2" '{code:$code,detail:$detail}')")
}

add_hard_block() {
  hard_blocks+=("$(jq -n --arg code "$1" --arg detail "$2" '{code:$code,detail:$detail}')")
}

items_json() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -s '.'
  fi
}

strings_json() {
  if (( $# == 0 )); then
    print -r -- '[]'
  else
    printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0)) | unique'
  fi
}

valid_relative_path() {
  local relative_path="$1"
  [[ -n "$relative_path" && "$relative_path" != /* && "$relative_path" != *'//'* \
     && "$relative_path" != '.' && "$relative_path" != '..' \
     && "$relative_path" != './'* && "$relative_path" != '../'* \
     && "$relative_path" != *'/./'* && "$relative_path" != *'/../'* \
     && "$relative_path" != *'/.' && "$relative_path" != *'/..' \
     && "$relative_path" == [A-Za-z0-9._+@/-]## ]]
}

while (( $# > 0 )); do
  case "$1" in
    --variant)
      (( $# >= 2 )) || { usage; exit 2; }
      requested_variants+=("$2")
      shift 2
      ;;
    --command)
      (( $# >= 2 )) || { usage; exit 2; }
      command_names+=("$2")
      command_relative_paths[$2]="bin/$2"
      shift 2
      ;;
    --command-path)
      (( $# >= 2 )) || { usage; exit 2; }
      typeset command_path_spec="$2"
      typeset command_path_name="${command_path_spec%%=*}"
      typeset command_relative_path="${command_path_spec#*=}"
      [[ "$command_path_spec" == *=* && -n "$command_path_name" && -n "$command_relative_path" ]] || {
        print -u2 -- "invalid command path: $command_path_spec"
        exit 2
      }
      command_names+=("$command_path_name")
      command_relative_paths[$command_path_name]="$command_relative_path"
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
typeset port_name="$1"
[[ "$port_name" == [A-Za-z0-9._+-]## ]] || { print -u2 'invalid port name'; exit 2; }
for requested_variant in "${requested_variants[@]}"; do
  [[ "$requested_variant" == [+-][A-Za-z0-9._+-]## ]] || { print -u2 "invalid variant: $requested_variant"; exit 2; }
done
for command_name in "${command_names[@]}"; do
  [[ "$command_name" == [A-Za-z0-9._+-]## ]] || { print -u2 "invalid command: $command_name"; exit 2; }
  valid_relative_path "${command_relative_paths[$command_name]}" || {
    print -u2 -- "invalid prefix-relative command path: ${command_relative_paths[$command_name]}"
    exit 2
  }
done
command_names=("${(@u)command_names}")

typeset jq_bin port_bin curl_bin file_bin otool_bin tar_bin shasum_bin
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  jq_bin="${IHBM_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  port_bin="${IHBM_PORT_BIN:-$(command -v port 2>/dev/null || true)}"
  curl_bin="${IHBM_CURL_BIN:-$(command -v curl 2>/dev/null || true)}"
  file_bin="${IHBM_FILE_BIN:-$(command -v file 2>/dev/null || true)}"
  otool_bin="${IHBM_OTOOL_BIN:-$(command -v otool 2>/dev/null || true)}"
  tar_bin="${IHBM_TAR_BIN:-$(command -v tar 2>/dev/null || true)}"
  shasum_bin="${IHBM_SHASUM_BIN:-$(command -v shasum 2>/dev/null || true)}"
else
  for candidate in /opt/local/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    [[ -x "$candidate" ]] && { jq_bin="$candidate"; break; }
  done
  port_bin=/opt/local/bin/port
  curl_bin=/usr/bin/curl
  file_bin=/usr/bin/file
  otool_bin=/usr/bin/otool
  tar_bin=/usr/bin/tar
  shasum_bin=/usr/bin/shasum
fi
[[ -n "$jq_bin" && -n "$port_bin" && -n "$curl_bin" && -n "$file_bin" && -n "$tar_bin" && -n "$shasum_bin" ]] || {
  print -u2 'jq, port, curl, file, tar, and shasum are required'
  exit 2
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ihbm-archive.XXXXXX")" || exit 3
trap cleanup EXIT INT TERM

typeset recorded_utc recorded_local product_version build_version architecture kernel_release darwin_major port_version port_revision
recorded_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
recorded_local="$(/bin/date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
product_version="$(/usr/bin/sw_vers -productVersion)"
build_version="$(/usr/bin/sw_vers -buildVersion)"
architecture="$(/usr/bin/uname -m)"
kernel_release="$(/usr/bin/uname -r)"
darwin_major="${kernel_release%%.*}"
port_version="$($port_bin info --version --line "$port_name" 2>/dev/null | sed -n '1p')"
port_revision="$($port_bin info --revision --line "$port_name" 2>/dev/null | sed -n '1p')"
[[ -n "$port_version" && -n "$port_revision" ]] || {
  print -u2 'cannot resolve port version or revision'
  exit 3
}

typeset variant_suffix=''
if (( ${#requested_variants} > 0 )); then
  variant_suffix="$(printf '%s\n' "${requested_variants[@]}" | sort | tr -d '\n')"
fi
typeset archive_base='https://packages.macports.org'
typeset archive_index_file='' cache_dir=''
typeset -a curl_security_args=(--proto '=https' --proto-redir '=https')
if [[ "${IHBM_TEST_MODE:-0}" == 1 ]]; then
  archive_base="${IHBM_ARCHIVE_BASE_URL:-$archive_base}"
  archive_index_file="${IHBM_ARCHIVE_INDEX_FILE:-}"
  cache_dir="${IHBM_ARCHIVE_CACHE_DIR:-}"
  curl_security_args=()
fi
typeset index_content=''
if [[ -n "$archive_index_file" ]]; then
  [[ "$archive_index_file" == /* && -r "$archive_index_file" && ! -L "$archive_index_file" ]] || {
    print -u2 'test archive index must be an absolute, readable, non-symlink file'
    exit 2
  }
  index_content="$(<"$archive_index_file")"
else
  index_content="$($curl_bin "${curl_security_args[@]}" --fail --silent --show-error --location --max-time 30 "${archive_base%/}/${port_name}/" 2>"$temp_dir/index.stderr")"
  if (( $? != 0 )); then
    add_error 'archive_index_fetch' "$(<"$temp_dir/index.stderr")"
    add_hard_block 'remote_archive_index_unavailable' "cannot fetch archive index for $port_name"
  fi
fi
if (( ${#index_content} > 1048576 )); then
  index_content=''
  add_hard_block 'archive_index_too_large' 'archive index exceeds the 1 MiB evidence limit'
fi

typeset archive_stem="${port_name}-${port_version}_${port_revision}${variant_suffix}"
typeset archive_name=''
typeset -a archive_candidates compatible_suffixes
if [[ -n "$index_content" ]]; then
  archive_candidates=("${(@f)$(print -r -- "$index_content" | grep -Eo '[A-Za-z0-9._+@-]+[.]tbz2' | sort -u)}")
  compatible_suffixes=(
    "darwin_${darwin_major}.${architecture}.tbz2"
    "darwin_${darwin_major}.noarch.tbz2"
    "darwin_any.${architecture}.tbz2"
    "darwin_any.noarch.tbz2"
    "any_any.${architecture}.tbz2"
    "any_any.noarch.tbz2"
  )
  for compatible_suffix in "${compatible_suffixes[@]}"; do
    typeset expected_name="${archive_stem}.${compatible_suffix}"
    if (( ${archive_candidates[(Ie)$expected_name]} > 0 )); then
      archive_name="$expected_name"
      break
    fi
  done
fi

typeset archive_url='' signature_url=''
typeset archive_structure_verified=false signature_present=false archive_size=0 archive_sha256='' manifest_json='null'
typeset archive_path=''
if [[ -z "$archive_name" ]]; then
  add_hard_block 'remote_archive_unavailable' "no compatible public archive matches $archive_stem on Darwin $darwin_major/$architecture"
else
  archive_url="${archive_base%/}/${port_name}/${archive_name}"
  signature_url="${archive_url}.rmd160"
  typeset signature_path="$temp_dir/archive.rmd160"
  archive_path="$temp_dir/$archive_name"
  if [[ -n "$cache_dir" ]]; then
    [[ "$cache_dir" == /* && "$cache_dir" != *'/../'* && "$cache_dir" != *'/..' ]] || {
      print -u2 'test archive cache must be an absolute traversal-free path'
      exit 2
    }
    mkdir -p "$cache_dir/$port_name"
    chmod 0700 "$cache_dir" "$cache_dir/$port_name" 2>/dev/null || true
    archive_path="$cache_dir/$port_name/$archive_name"
    signature_path="$cache_dir/$port_name/$archive_name.rmd160"
  fi
  if [[ -s "$signature_path" ]] || $curl_bin "${curl_security_args[@]}" --fail --silent --show-error --location --max-time 30 --max-filesize 1048576 --output "$signature_path.part" "$signature_url" 2>"$temp_dir/signature.stderr"; then
    [[ -s "$signature_path" ]] || mv -f -- "$signature_path.part" "$signature_path"
    signature_present=true
  else
    rm -f -- "$signature_path.part"
    add_error 'archive_signature_fetch' "$(<"$temp_dir/signature.stderr")"
    add_hard_block 'archive_signature_unavailable' "cannot fetch ${archive_name}.rmd160"
  fi

  if [[ ! -s "$archive_path" ]] && ! $curl_bin "${curl_security_args[@]}" --fail --silent --show-error --location --connect-timeout 20 --max-time 600 --max-filesize 2147483648 --output "$archive_path.part" "$archive_url" 2>"$temp_dir/archive.stderr"; then
    rm -f -- "$archive_path.part"
    add_error 'archive_fetch' "$(<"$temp_dir/archive.stderr")"
    add_hard_block 'remote_archive_fetch_failed' "cannot fetch $archive_url"
  else
    [[ -s "$archive_path" ]] || mv -f -- "$archive_path.part" "$archive_path"
    archive_size="$(stat -f '%z' "$archive_path")"
    archive_sha256="$($shasum_bin -a 256 "$archive_path" | awk '{print $1}')"
    typeset manifest=''
    manifest="$($tar_bin -xOjf "$archive_path" +CONTENTS 2>"$temp_dir/manifest.stderr")"
    if (( $? != 0 )) || [[ -z "$manifest" ]]; then
      add_error 'archive_manifest' "$(<"$temp_dir/manifest.stderr")"
      add_hard_block 'archive_manifest_unreadable' "$archive_name has no readable +CONTENTS"
    else
      typeset manifest_name manifest_port manifest_version manifest_revision manifest_arch manifest_os
      typeset manifest_variants requested_variant_lines manifest_variant_lines
      manifest_name="$(print -r -- "$manifest" | sed -n 's/^@name //p')"
      manifest_port="$(print -r -- "$manifest" | sed -n 's/^@portname //p')"
      manifest_version="$(print -r -- "$manifest" | sed -n 's/^@portversion //p')"
      manifest_revision="$(print -r -- "$manifest" | sed -n 's/^@portrevision //p')"
      manifest_arch="$(print -r -- "$manifest" | sed -n 's/^@archs //p')"
      manifest_os="$(print -r -- "$manifest" | sed -n 's/^@os.version //p')"
      manifest_variant_lines="$(print -r -- "$manifest" | sed -n 's/^@portvariant //p' | sort)"
      requested_variant_lines="$(printf '%s\n' "${requested_variants[@]}" | sed '/^$/d' | sort)"
      manifest_variants="$(print -r -- "$manifest_variant_lines" | jq -R -s 'split("\n") | map(select(length > 0))')"
      manifest_json="$($jq_bin -n \
        --arg name "$manifest_name" --arg port "$manifest_port" \
        --arg version "$manifest_version" --arg revision "$manifest_revision" \
        --arg architecture "$manifest_arch" --arg os_version "$manifest_os" \
        --argjson variants "$manifest_variants" \
        '{name:$name,port:$port,version:$version,revision:$revision,architecture:$architecture,os_version:$os_version,variants:$variants}')"
      [[ "$manifest_port" == "$port_name" && "$manifest_version" == "$port_version" && "$manifest_revision" == "$port_revision" ]] || \
        add_hard_block 'archive_manifest_identity_mismatch' "$archive_name manifest does not match the selected port"
      [[ "$manifest_variant_lines" == "$requested_variant_lines" ]] || \
        add_hard_block 'archive_manifest_variant_mismatch' "$archive_name manifest variants do not match the requested variants"
      [[ "$manifest_arch" == noarch || "$manifest_arch" == *"$architecture"* ]] || \
        add_hard_block 'archive_architecture_mismatch' "$archive_name manifest architecture is $manifest_arch, expected $architecture or noarch"

      for command_name in "${command_names[@]}"; do
        typeset relative_path="${command_relative_paths[$command_name]}"
        typeset archive_entry='' source_entry='' extracted_command='' file_output='' dynamic_output='' cross_output=''
        typeset entry_listing='' link_target=''
        archive_entry="$($tar_bin -tjf "$archive_path" | awk -v wanted="opt/local/$relative_path" '$0 == wanted || $0 == "./" wanted { print; exit }')"
        if [[ -z "$archive_entry" ]]; then
          add_hard_block 'archive_command_missing' "$relative_path is absent from $archive_name"
          continue
        fi
        source_entry="$archive_entry"
        entry_listing="$($tar_bin -tvjf "$archive_path" "$archive_entry" 2>/dev/null)"
        if [[ "$entry_listing" == *' -> '* ]]; then
          link_target="${entry_listing##* -> }"
          if [[ "$link_target" == */* || "$link_target" == '.' || "$link_target" == '..' ]]; then
            add_hard_block 'archive_command_symlink_unsafe' "$relative_path has unsupported symlink target $link_target"
            continue
          fi
          source_entry="${archive_entry:h}/$link_target"
          if ! $tar_bin -tjf "$archive_path" | grep -Fxq "$source_entry"; then
            add_hard_block 'archive_command_symlink_target_missing' "$relative_path points to absent archive entry $source_entry"
            continue
          fi
        fi
        extracted_command="$temp_dir/command-${command_name}"
        $tar_bin -xOjf "$archive_path" "$source_entry" >"$extracted_command" 2>"$temp_dir/command.stderr"
        if (( $? != 0 )); then
          add_error "archive_command_extract:$command_name" "$(<"$temp_dir/command.stderr")"
          continue
        fi
        chmod 0755 "$extracted_command"
        file_output="$($file_bin "$extracted_command" 2>&1)"
        if [[ "$file_output" == *Mach-O* && "$architecture" == x86_64 && "$file_output" != *x86_64* ]]; then
          add_hard_block 'candidate_architecture_mismatch' "$relative_path is not x86_64"
        fi
        if [[ -n "$otool_bin" && "$file_output" == *Mach-O* ]]; then
          dynamic_output="$($otool_bin -L "$extracted_command" 2>/dev/null | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p')"
          cross_output="$(print -r -- "$dynamic_output" | grep '^/usr/local/' || true)"
          [[ -z "$cross_output" ]] || add_hard_block 'cross_prefix_linkage' "$relative_path links to Homebrew"
        fi
        command_items+=("$($jq_bin -n --arg name "$command_name" --arg relative_path "$relative_path" --arg file_output "$file_output" \
          --argjson dynamic_links "$(print -r -- "$dynamic_output" | jq -R -s 'split("\n") | map(select(length > 0))')" \
          --argjson cross_prefix_links "$(print -r -- "$cross_output" | jq -R -s 'split("\n") | map(select(length > 0))')" \
          '{name:$name,relative_path:$relative_path,file_output:$file_output,dynamic_links:$dynamic_links,cross_prefix_links:$cross_prefix_links}')")
      done
    fi
  fi
fi

[[ "$architecture" == x86_64 ]] || add_hard_block 'unsupported_architecture' "expected x86_64, found $architecture"
(( ${#hard_blocks} == 0 && ${#errors} == 0 )) && archive_structure_verified=true

typeset variants_json commands_json errors_json warnings_json hard_blocks_json
variants_json="$(strings_json "${requested_variants[@]}")"
commands_json="$(items_json "${command_items[@]}")"
errors_json="$(items_json "${errors[@]}")"
warnings_json="$(items_json "${warnings[@]}")"
hard_blocks_json="$(items_json "${hard_blocks[@]}")"

$jq_bin -n \
  --argjson schema_version 2 \
  --arg recorded_utc "$recorded_utc" --arg recorded_local "$recorded_local" \
  --arg product_version "$product_version" --arg build_version "$build_version" \
  --arg architecture "$architecture" --arg kernel_release "$kernel_release" \
  --arg port_name "$port_name" --arg port_version "$port_version" --arg port_revision "$port_revision" \
  --argjson variants "$variants_json" --arg url "$archive_url" --arg signature_url "$signature_url" --arg archive_name "$archive_name" \
  --argjson size "$archive_size" --arg sha256 "$archive_sha256" --argjson manifest "$manifest_json" \
  --argjson signature_present "$signature_present" --argjson verified "$archive_structure_verified" --argjson commands "$commands_json" \
  --argjson warnings "$warnings_json" --argjson hard_blocks "$hard_blocks_json" --argjson errors "$errors_json" \
  '{schema_version:$schema_version,recorded_at:{utc:$recorded_utc,local:$recorded_local},
    host:{product_version:$product_version,build_version:$build_version,architecture:$architecture,kernel_release:$kernel_release},
    port:{name:$port_name,version:$port_version,revision:$port_revision,variants:$variants},
    archive:{name:(if ($archive_name|length)>0 then $archive_name else null end),url:(if ($url|length)>0 then $url else null end),signature_url:(if ($signature_url|length)>0 then $signature_url else null end),signature_present:$signature_present,size:$size,sha256:(if ($sha256|length)>0 then $sha256 else null end),manifest:$manifest},
    commands:$commands,archive_structure_verified:$verified,macports_signature_verified:false,requires_port_b_install:true,
    mutations_performed:false,warnings:$warnings,hard_blocks:$hard_blocks,errors:$errors}'
