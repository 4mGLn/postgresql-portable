#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bundle_runtime_deps.sh --prefix <install-prefix> --target <target>

Normalizes the runtime layout of a PostgreSQL install tree and copies
non-system shared-library dependencies into the bundle when needed.
EOF
}

prefix=""
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$prefix" || -z "$target" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$prefix" ]]; then
  echo "Install prefix not found: $prefix" >&2
  exit 1
fi

realpath_existing() {
  perl -MCwd=realpath -e 'print realpath(shift)' "$1"
}

prefix="$(realpath_existing "$prefix")"
lib_dir="${prefix}/lib"
bin_dir="${prefix}/bin"
module_dir="${lib_dir}/postgresql"

warn() {
  echo "WARN: $*" >&2
}

collect_files() {
  find "$bin_dir" "$lib_dir" "$module_dir" \
    \( -type f -o -type l \) \
    \( -perm -u+x -o -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dll' -o -name '*.exe' \) \
    -print0 2>/dev/null
}

copy_dependency_file() {
  local source="$1"
  local destination_dir="$2"
  local basename resolved

  basename="$(basename "$source")"
  resolved="$(realpath_existing "$source")"

  install -m 755 "$resolved" "${destination_dir}/${basename}"
}

linux_skip_dependency() {
  local basename
  basename="$(basename "$1")"
  case "$basename" in
    linux-vdso.so.*|ld-linux*.so*|libc.so.*|libm.so.*|libpthread.so.*|librt.so.*|libdl.so.*|libresolv.so.*|libnsl.so.*|libutil.so.*|libcrypt.so.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

linux_set_rpaths() {
  local file rpath

  if ! command -v patchelf >/dev/null 2>&1; then
    warn "patchelf is not installed; skipping ELF RPATH normalization"
    return 0
  fi

  while IFS= read -r -d '' file; do
    if ! file "$file" | grep -q 'ELF'; then
      continue
    fi

    # shellcheck disable=SC2016
    case "$file" in
      "${bin_dir}"/*) rpath='$ORIGIN/../lib' ;;
      "${module_dir}"/*) rpath='$ORIGIN/..:$ORIGIN/../..' ;;
      "${lib_dir}"/*) rpath='$ORIGIN' ;;
      *) continue ;;
    esac

    chmod u+w "$file" || true
    patchelf --force-rpath --set-rpath "$rpath" "$file"
  done < <(collect_files)
}

bundle_linux() {
  local file dep
  declare -A seen=()

  mkdir -p "$lib_dir"
  linux_set_rpaths

  while IFS= read -r -d '' file; do
    if ! file "$file" | grep -q 'ELF'; then
      continue
    fi

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      [[ "$dep" == "$prefix"* ]] && continue
      linux_skip_dependency "$dep" && continue
      if [[ -n "${seen[$dep]:-}" ]]; then
        continue
      fi
      seen["$dep"]=1
      copy_dependency_file "$dep" "$lib_dir"
    done < <(
      ldd "$file" 2>/dev/null \
        | awk '
            /=> \// { print $3 }
            /^\// { print $1 }
          ' \
        | sort -u
    )
  done < <(collect_files)

  linux_set_rpaths
}

macos_add_rpath() {
  local file="$1"
  local value="$2"

  install_name_tool -add_rpath "$value" "$file" 2>/dev/null || true
}

macos_normalize_file() {
  local file="$1"
  local base

  chmod u+w "$file" || true

  case "$file" in
    "${bin_dir}"/*)
      macos_add_rpath "$file" "@loader_path/../lib"
      ;;
    "${module_dir}"/*)
      macos_add_rpath "$file" "@loader_path/.."
      macos_add_rpath "$file" "@loader_path/../.."
      ;;
    "${lib_dir}"/*)
      base="$(basename "$file")"
      install_name_tool -id "@rpath/${base}" "$file" 2>/dev/null || true
      macos_add_rpath "$file" "@loader_path"
      ;;
  esac
}

bundle_macos() {
  local -a queue=()
  local file dep dest rewritten
  declare -A queued=()

  while IFS= read -r -d '' file; do
    queue+=("$file")
    queued["$file"]=1
  done < <(collect_files)

  local qi=0
  while [[ $qi -lt ${#queue[@]} ]]; do
    file="${queue[$qi]}"
    (( qi++ ))

    if ! file "$file" | grep -q 'Mach-O'; then
      continue
    fi

    macos_normalize_file "$file"

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      case "$dep" in
        /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*)
          continue
          ;;
      esac

      rewritten="@rpath/$(basename "$dep")"
      if [[ "$dep" == "$prefix"* ]]; then
        chmod u+w "$file" || true
        install_name_tool -change "$dep" "$rewritten" "$file" 2>/dev/null || true
        if [[ -z "${queued[$dep]:-}" ]]; then
          queue+=("$dep")
          queued["$dep"]=1
        fi
        continue
      fi

      dest="${lib_dir}/$(basename "$dep")"
      if [[ ! -e "$dest" ]]; then
        copy_dependency_file "$dep" "$lib_dir"
        chmod u+w "$dest" || true
        install_name_tool -id "$rewritten" "$dest" 2>/dev/null || true
        queue+=("$dest")
        queued["$dest"]=1
      fi

      chmod u+w "$file" || true
      install_name_tool -change "$dep" "$rewritten" "$file" 2>/dev/null || true
    done < <(otool -L "$file" | awk 'NR > 1 { print $1 }')
  done
}

windows_skip_dependency() {
  local upper
  upper="$(printf '%s' "$(basename "$1")" | tr '[:lower:]' '[:upper:]')"
  case "$upper" in
    ADVAPI32.DLL|BCRYPT.DLL|COMCTL32.DLL|COMDLG32.DLL|CRYPT32.DLL|GDI32.DLL|IMM32.DLL|KERNEL32.DLL|NTDLL.DLL|OLE32.DLL|RPCRT4.DLL|SECHOST.DLL|SHELL32.DLL|SHLWAPI.DLL|USER32.DLL|VERSION.DLL|WS2_32.DLL)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_windows_dependency() {
  local dll="$1"
  local dir
  IFS=':' read -r -a path_parts <<< "${PATH:-}"
  for dir in "${path_parts[@]}"; do
    [[ -z "$dir" ]] && continue
    if [[ -e "${dir}/${dll}" ]]; then
      printf '%s\n' "${dir}/${dll}"
      return 0
    fi
  done
  return 1
}

bundle_windows() {
  local file dep resolved dest
  declare -A seen=()

  while IFS= read -r -d '' file; do
    case "$file" in
      *.dll|*.exe) ;;
      *) continue ;;
    esac

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      windows_skip_dependency "$dep" && continue
      if [[ -n "${seen[$dep]:-}" ]]; then
        continue
      fi
      resolved="$(resolve_windows_dependency "$dep" || true)"
      if [[ -z "$resolved" || "$resolved" == "$bin_dir/"* ]]; then
        continue
      fi
      dest="${bin_dir}/$(basename "$dep")"
      copy_dependency_file "$resolved" "$bin_dir"
      seen["$dep"]=1
      chmod u+w "$dest" || true
    done < <(objdump -p "$file" 2>/dev/null | awk '/DLL Name:/ { print $3 }' | sort -u)
  done < <(collect_files)
}

case "$target" in
  unknown-linux_*)
    bundle_linux
    ;;
  macos_*)
    bundle_macos
    ;;
  windows_*)
    bundle_windows
    ;;
  *)
    echo "Unsupported target: $target" >&2
    exit 1
    ;;
esac
