#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Extension build failed at line $LINENO" >&2' ERR

usage() {
  cat <<'EOF'
Usage: build_extension_overlay.sh --major <major> --target <target> --extension <name> --install-prefix <path> [--config <path>] [--output-dir <path>] [--work-dir <path>] [--jobs <n>]

Builds a separate overlay archive for a third-party PostgreSQL extension against an
already-installed portable PostgreSQL prefix.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

detect_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
    return 0
  fi
  printf '4\n'
}

config="${REPO_ROOT}/ci/postgresql-release-config.json"
major=""
target=""
extension=""
install_prefix=""
output_dir="${REPO_ROOT}/dist"
work_dir="${REPO_ROOT}/.work"
jobs="$(detect_jobs)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      config="${2:-}"
      shift 2
      ;;
    --major)
      major="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --extension)
      extension="${2:-}"
      shift 2
      ;;
    --install-prefix)
      install_prefix="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --work-dir)
      work_dir="${2:-}"
      shift 2
      ;;
    --jobs)
      jobs="${2:-}"
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

if [[ -z "$major" || -z "$target" || -z "$extension" || -z "$install_prefix" ]]; then
  usage >&2
  exit 1
fi

if [[ "$work_dir" != /* ]]; then
  work_dir="${REPO_ROOT}/${work_dir}"
fi
if [[ "$output_dir" != /* ]]; then
  output_dir="${REPO_ROOT}/${output_dir}"
fi

mkdir -p "$work_dir" "$output_dir"

realpath_existing() {
  perl -MCwd=realpath -e 'print realpath(shift)' "$1"
}

install_prefix="$(realpath_existing "$install_prefix")"

# shellcheck disable=SC1090
source <("${SCRIPT_DIR}/get_release_vars.sh" --config "$config" --major "$major" --target "$target")

extension_repo="$(jq -r --arg ext "$extension" '.separate_extensions[$ext].repo // empty' "$config")"
extension_ref="$(jq -r --arg ext "$extension" --arg major "$major" '.separate_extensions[$ext].refs[$major] // .separate_extensions[$ext].ref // empty' "$config")"
extension_sql_name="$(jq -r --arg ext "$extension" '.separate_extensions[$ext].sql_name // $ext' "$config")"
bundle_target="${TARGET:-$target}"

if [[ -z "$extension_repo" ]]; then
  echo "Extension $extension is not defined under .separate_extensions in $config" >&2
  exit 1
fi

ext_root="${work_dir}/extension-${extension}-${PG_VERSION}-${bundle_target}"
ext_src="${ext_root}/src/${extension}"
ext_stage="${ext_root}/stage"
ext_stage_prefix="${ext_stage}/${install_prefix#/}"
ext_package_root="${ext_root}/package/${RELEASE_NAME_PREFIX}-${extension}-${PG_VERSION}-${bundle_target}"
ext_archive="${output_dir}/${RELEASE_NAME_PREFIX}-${extension}-${PG_VERSION}-${bundle_target}.${ARCHIVE_FORMAT}"

rm -rf "$ext_root"
mkdir -p "${ext_root}/src" "$ext_stage" "$ext_package_root"

# On MSYS2, pg_config returns Windows-style paths (D:/a/...) but DESTDIR is
# Unix-style (/d/a/.../stage). PGXS concatenates $(DESTDIR)$(prefix) directly,
# producing broken paths like "stageD:/a/..." where MSYS2 interprets D: as a
# drive letter and installs files outside the staging area entirely.
# Fix: wrap pg_config to convert its output to Unix-style paths.
pg_config_cmd="${install_prefix}/bin/pg_config"
if command -v cygpath >/dev/null 2>&1; then
  pg_config_cmd="${ext_root}/pg_config_unix"
  cat > "$pg_config_cmd" <<EOF
#!/bin/bash
out="\$(${install_prefix}/bin/pg_config "\$@")"
[[ "\$out" =~ ^[A-Za-z]:/ ]] && out="\$(cygpath -u "\$out")"
printf '%s\\n' "\$out"
EOF
  chmod +x "$pg_config_cmd"
  ext_stage_prefix="${ext_stage}/$("$pg_config_cmd" --prefix | sed 's|^/||')"
fi

if [[ -n "$extension_ref" ]]; then
  git clone --depth 1 --branch "$extension_ref" "$extension_repo" "$ext_src"
else
  git clone --depth 1 "$extension_repo" "$ext_src"
fi

pushd "$ext_src" >/dev/null

# On Windows/MinGW, PGXS expects win32ver.rc for version resource embedding.
if [[ "$target" == *windows* ]] && [[ ! -f win32ver.rc ]]; then
  printf '#include <winver.h>\nVS_VERSION_INFO VERSIONINFO BEGIN END\n' > win32ver.rc
fi

make clean >/dev/null 2>&1 || true
PATH="${install_prefix}/bin:${PATH}" make -j"$jobs" USE_PGXS=1 PG_CONFIG="$pg_config_cmd"
PATH="${install_prefix}/bin:${PATH}" make USE_PGXS=1 PG_CONFIG="$pg_config_cmd" DESTDIR="$ext_stage" install
popd >/dev/null

if [[ ! -d "$ext_stage_prefix" ]]; then
  echo "ERROR: Extension $extension did not stage files beneath ${ext_stage_prefix}" >&2
  echo "  install_prefix: $install_prefix" >&2
  echo "  pg_config --prefix: $("$pg_config_cmd" --prefix)" >&2
  echo "  Contents of stage dir:" >&2
  find "$ext_stage" -type f 2>/dev/null | head -20 >&2 || true
  exit 1
fi

cp -a "${ext_stage_prefix}/." "$ext_package_root/"

{
  printf 'Portable PostgreSQL extension overlay: %s\n' "$extension"
  printf 'PostgreSQL version: %s\n' "$PG_VERSION"
  printf 'Target: %s\n' "$TARGET"
  printf 'Repository: %s\n' "$extension_repo"
  if [[ -n "$extension_ref" ]]; then
    printf 'Ref: %s\n' "$extension_ref"
  fi
  printf '\nInstall by extracting this archive over the matching PostgreSQL base package.\n'
  printf 'Enable with: CREATE EXTENSION %s;\n' "$extension_sql_name"
  printf '\nNotes:\n'
  jq -r --arg ext "$extension" '.separate_extensions[$ext].notes[]? // empty' "$config" | sed 's/^/- /'
} > "${ext_package_root}/EXTENSION-README.txt"

rm -f "$ext_archive" "${ext_archive}.sha256"
pushd "$(dirname "$ext_package_root")" >/dev/null
case "$ARCHIVE_FORMAT" in
  tar.gz)
    tar -czf "$ext_archive" "$(basename "$ext_package_root")"
    ;;
  zip)
    zip -qr "$ext_archive" "$(basename "$ext_package_root")"
    ;;
  *)
    echo "Unsupported archive format: $ARCHIVE_FORMAT" >&2
    exit 1
    ;;
esac
popd >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ext_archive" > "${ext_archive}.sha256"
else
  shasum -a 256 "$ext_archive" > "${ext_archive}.sha256"
fi

echo "Created ${ext_archive}"
