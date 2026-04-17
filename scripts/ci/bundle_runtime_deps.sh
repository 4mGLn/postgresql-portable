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
    # Windows kernel / core Win32
    ADVAPI32.DLL|BCRYPT.DLL|COMCTL32.DLL|COMDLG32.DLL|CRYPT32.DLL|\
    GDI32.DLL|IMM32.DLL|KERNEL32.DLL|NTDLL.DLL|OLE32.DLL|OLEAUT32.DLL|\
    RPCRT4.DLL|SECHOST.DLL|SHELL32.DLL|SHLWAPI.DLL|USER32.DLL|\
    VERSION.DLL|WS2_32.DLL)
      return 0
      ;;
    # C / C++ runtime — ships with Windows or the Visual C++ Redistributable
    MSVCRT.DLL|UCRTBASE.DLL|MSVCP*.DLL|VCRUNTIME*.DLL)
      return 0
      ;;
    # Universal CRT forwarder DLLs (api-ms-win-crt-*, api-ms-win-core-*, ext-ms-win-*)
    API-MS-WIN-*|EXT-MS-WIN-*)
      return 0
      ;;
    # Networking and system services — built into every Windows installation
    DNSAPI.DLL|IPHLPAPI.DLL|NETAPI32.DLL|PSAPI.DLL|SECUR32.DLL|\
    USERENV.DLL|WINMM.DLL|MPR.DLL|DBGHELP.DLL)
      return 0
      ;;
    # Windows built-in LDAP and Kerberos/SSPI (used by --with-ldap / --with-gssapi)
    WLDAP32.DLL|SSPICLI.DLL|KERBEROS.DLL)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_windows_dependency() {
  local dll="$1"
  local dir found
  IFS=':' read -r -a path_parts <<< "${PATH:-}"
  for dir in "${path_parts[@]}"; do
    [[ -z "$dir" || ! -d "$dir" ]] && continue
    # Use find -iname for case-insensitive matching: objdump may report DLL
    # names in a different case than the actual filename on disk.
    found="$(find "$dir" -maxdepth 1 -iname "$dll" -print -quit 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 1
}

bundle_windows() {
  local dep resolved dest
  declare -A seen=()
  local -a queue=()

  # Seed the queue with all executables and DLLs already in the install tree.
  while IFS= read -r -d '' file; do
    case "$file" in
      *.dll|*.exe) queue+=("$file") ;;
    esac
  done < <(collect_files)

  # BFS: re-scan each newly copied DLL so transitive deps are also bundled
  # (e.g. libgcc_s_seh-1.dll → libwinpthread-1.dll).
  local qi=0
  while [[ $qi -lt ${#queue[@]} ]]; do
    local file="${queue[$qi]}"
    (( qi++ ))

    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      windows_skip_dependency "$dep" && continue
      # Normalise to lowercase so DLL names from different import tables
      # that differ only in case don't get bundled twice.
      local dep_lower
      dep_lower="$(printf '%s' "$dep" | tr '[:upper:]' '[:lower:]')"
      [[ -n "${seen[$dep_lower]:-}" ]] && continue
      seen["$dep_lower"]=1

      resolved="$(resolve_windows_dependency "$dep" || true)"
      [[ -z "$resolved" ]] && continue

      dest="${bin_dir}/$(basename "$resolved")"
      # Skip if already present in the bundle (either original or previously copied).
      [[ -e "$dest" ]] && continue

      copy_dependency_file "$resolved" "$bin_dir"
      chmod u+w "$dest" || true
      # Enqueue so its own deps are scanned in a later iteration.
      queue+=("$dest")
    done < <(objdump -p "$file" 2>/dev/null | awk '/DLL Name:/ { print $3 }' | sort -u)
  done

  # ICU loads its data DLL (libicudt*.dll) at runtime via internal discovery
  # rather than a PE import entry, so objdump never reports it as a dependency.
  # Find any libicuuc*.dll we bundled and copy the matching libicudt*.dll too.
  local icuuc icudt_name icudt_resolved
  while IFS= read -r icuuc; do
    icudt_name="$(basename "$icuuc" | sed 's/libicuuc/libicudt/i')"
    if [[ ! -e "${bin_dir}/${icudt_name}" ]]; then
      icudt_resolved="$(resolve_windows_dependency "$icudt_name" || true)"
      if [[ -n "$icudt_resolved" ]]; then
        copy_dependency_file "$icudt_resolved" "$bin_dir"
        warn "Explicitly bundled ICU data DLL: ${icudt_name} (not in PE import table)"
      else
        warn "Could not find ICU data DLL ${icudt_name} — ICU locale/collation may fail at runtime"
      fi
    fi
  done < <(find "$bin_dir" -maxdepth 1 -iname 'libicuuc*.dll' 2>/dev/null)
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
