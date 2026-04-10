#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Build failed at line $LINENO" >&2' ERR

usage() {
  cat <<'EOF'
Usage: build_portable_postgresql.sh --major <major> --target <target> [--config <path>] [--output-dir <path>] [--work-dir <path>] [--jobs <n>]

Builds an upstream PostgreSQL release into a relocatable archive for the requested
target family.
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

if [[ -z "$major" || -z "$target" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$config" ]]; then
  echo "Config file not found: $config" >&2
  exit 1
fi

if [[ "$work_dir" != /* ]]; then
  work_dir="${REPO_ROOT}/${work_dir}"
fi
if [[ "$output_dir" != /* ]]; then
  output_dir="${REPO_ROOT}/${output_dir}"
fi

mkdir -p "$work_dir" "$output_dir"

# shellcheck disable=SC1090
source <("${SCRIPT_DIR}/get_release_vars.sh" --config "$config" --major "$major" --target "$target")

bundle_target="${TARGET:-$target}"
build_root="${work_dir}/build-${PG_VERSION}-${bundle_target}"
source_archive="${build_root}/${SOURCE_ARCHIVE_BASENAME}"
source_root="${build_root}/src"
source_dir="${source_root}/postgresql-${PG_VERSION}"
build_dir="${build_root}/build"
install_root="${build_root}/install/${ARCHIVE_STEM}"
archive_path="${output_dir}/${ARCHIVE_BASENAME}"
env_file="${output_dir}/release-${PG_MAJOR}-${bundle_target}.env"

mkdir -p "$build_root" "$source_root" "$build_dir"
rm -rf "$install_root"
mkdir -p "$install_root"

require_tools() {
  local missing=0
  local tool
  for tool in curl tar make perl jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool: $tool" >&2
      missing=1
    fi
  done
  if (( missing != 0 )); then
    exit 1
  fi
}

verify_checksum() {
  local file="$1"
  local checksum_url="$2"
  local checksum_file="${file}.upstream-sha256"

  echo "Verifying SHA256 checksum from ${checksum_url}"
  if ! curl -fsSL "$checksum_url" -o "$checksum_file"; then
    echo "WARNING: Could not download upstream checksum file from ${checksum_url}" >&2
    rm -f "$checksum_file"
    return 0
  fi

  local expected
  expected="$(grep -F "$(basename "$file")" "$checksum_file" | awk '{print $1}')"
  rm -f "$checksum_file"

  if [[ -z "$expected" ]]; then
    echo "WARNING: No matching checksum entry found for $(basename "$file")" >&2
    return 0
  fi

  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "FATAL: SHA256 checksum mismatch for $(basename "$file")" >&2
    echo "  Expected: $expected" >&2
    echo "  Actual:   $actual" >&2
    return 1
  fi
  echo "SHA256 checksum verified: ${actual}"
}

download_source() {
  echo "Downloading PostgreSQL ${PG_VERSION} source from ${SOURCE_TARBALL_URL}"
  curl -fsSL "${SOURCE_TARBALL_URL}" -o "$source_archive"

  local checksum_url="${SOURCE_TARBALL_URL%.tar.gz}.tar.gz.sha256"
  verify_checksum "$source_archive" "$checksum_url"

  rm -rf "$source_dir"
  tar -xzf "$source_archive" -C "$source_root"
}

configure_postgresql() {
  local -a configure_flags=()
  mapfile -t configure_flags < <(jq -r '.portable.configure_flags[]?' "$config")

  pushd "$build_dir" >/dev/null
  "${source_dir}/configure" --prefix="$install_root" ${configure_flags[@]+"${configure_flags[@]}"}
  popd >/dev/null
}

build_postgresql() {
  pushd "$build_dir" >/dev/null
  make -j"$jobs"
  make install
  make -C contrib -j"$jobs"
  make -C contrib install
  popd >/dev/null
}

write_portable_helpers() {
  cat > "${install_root}/PORTABLE-README.txt" <<EOF
Portable PostgreSQL ${PG_VERSION}
Target: ${TARGET}

Contents:
- bin/: PostgreSQL executables
- contrib extensions are already installed in the base bundle, including
  pgcrypto, postgres_fdw, and hstore
- lib/: bundled shared libraries needed by the portable build
- share/: PostgreSQL shared data

Activation helpers:
- env.sh
- env.ps1
- env.cmd

Linux note:
- The Linux archive is built on the ${LINUX_BASELINE} userspace baseline to reduce
  host distribution coupling, but glibc/kernel compatibility still applies.
EOF

  cat > "${install_root}/env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${ROOT}/bin:${PATH}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  export DYLD_LIBRARY_PATH="${ROOT}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
else
  export LD_LIBRARY_PATH="${ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

echo "Portable PostgreSQL environment loaded from ${ROOT}"
EOF

  cat > "${install_root}/env.ps1" <<'EOF'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:Path = "$Root\bin;$env:Path"
Write-Host "Portable PostgreSQL environment loaded from $Root"
EOF

  cat > "${install_root}/env.cmd" <<'EOF'
@echo off
set ROOT=%~dp0
set PATH=%ROOT%bin;%PATH%
echo Portable PostgreSQL environment loaded from %ROOT%
EOF

  chmod +x "${install_root}/env.sh" "${install_root}/env.cmd"
}

build_external_overlays() {
  local extension

  mapfile -t extensions < <(jq -r '.separate_extensions | keys[]' "$config")
  for extension in "${extensions[@]}"; do
    "${SCRIPT_DIR}/build_extension_overlay.sh" \
      --config "$config" \
      --major "$PG_MAJOR" \
      --target "$TARGET" \
      --extension "$extension" \
      --install-prefix "$install_root" \
      --output-dir "$output_dir" \
      --work-dir "$work_dir" \
      --jobs "$jobs"
  done
}

create_archive() {
  rm -f "$archive_path" "${archive_path}.sha256"
  pushd "$(dirname "$install_root")" >/dev/null
  case "$ARCHIVE_FORMAT" in
    tar.gz)
      tar -czf "$archive_path" "$(basename "$install_root")"
      ;;
    zip)
      if ! command -v zip >/dev/null 2>&1; then
        echo "Missing required tool: zip" >&2
        exit 1
      fi
      zip -qr "$archive_path" "$(basename "$install_root")"
      ;;
    *)
      echo "Unsupported archive format: $ARCHIVE_FORMAT" >&2
      exit 1
      ;;
  esac
  popd >/dev/null

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$archive_path" > "${archive_path}.sha256"
  else
    shasum -a 256 "$archive_path" > "${archive_path}.sha256"
  fi
}

write_release_env() {
  {
    printf 'PG_MAJOR=%q\n' "$PG_MAJOR"
    printf 'PG_TAG=%q\n' "$PG_TAG"
    printf 'PG_VERSION=%q\n' "$PG_VERSION"
    printf 'TARGET=%q\n' "$TARGET"
    printf 'ARCHIVE_FORMAT=%q\n' "$ARCHIVE_FORMAT"
    printf 'ARCHIVE_STEM=%q\n' "$ARCHIVE_STEM"
    printf 'ARCHIVE_BASENAME=%q\n' "$ARCHIVE_BASENAME"
    printf 'ARCHIVE_PATH=%q\n' "$archive_path"
    printf 'ARTIFACT_NAME=%q\n' "$ARTIFACT_NAME"
    printf 'RELEASE_TAG=%q\n' "$RELEASE_TAG"
    printf 'RELEASE_TITLE=%q\n' "$RELEASE_TITLE"
    printf 'LINUX_BASELINE=%q\n' "$LINUX_BASELINE"
  } > "$env_file"
}

require_tools
download_source
configure_postgresql
build_postgresql
write_portable_helpers
"${SCRIPT_DIR}/bundle_runtime_deps.sh" --prefix "$install_root" --target "$TARGET"
build_external_overlays
create_archive
write_release_env

echo "Created ${archive_path}"
