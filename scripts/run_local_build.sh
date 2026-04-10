#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Bash 4+ is required (found ${BASH_VERSION})" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: run_local_build.sh --major <major> [--no-container] [additional build_portable_postgresql.sh args]

Builds the portable PostgreSQL archive for the current host platform.

On Linux, the build runs inside a manylinux2014 container (CentOS 7, glibc 2.17)
by default so the resulting binaries are portable to CentOS 7+ and all modern
distributions. Use --no-container to build directly on the host (the result will
only run on hosts with the same or newer glibc).

Requires Docker or Podman for containerized Linux builds.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

detect_target() {
  local system arch
  system="$(uname -s)"
  arch="$(uname -m)"

  case "$system" in
    Linux)
      [[ "$arch" == "x86_64" ]] || return 1
      printf 'unknown-linux_x86_64\n'
      ;;
    Darwin)
      case "$arch" in
        x86_64) printf 'macos_x86_64\n' ;;
        arm64) printf 'macos_aarch64\n' ;;
        *) return 1 ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      [[ "$arch" == "x86_64" ]] || return 1
      printf 'windows_x86_64\n'
      ;;
    *)
      return 1
      ;;
  esac
}

detect_container_runtime() {
  if command -v docker >/dev/null 2>&1; then
    printf 'docker\n'
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman\n'
  else
    return 1
  fi
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

use_container="auto"
passthrough_args=()

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-container)
      use_container="no"
      ;;
    *)
      passthrough_args+=("$arg")
      ;;
  esac
done

target="$(detect_target || true)"
if [[ -z "$target" ]]; then
  echo "Unsupported local host for portable build" >&2
  exit 1
fi

# On Linux, run inside the manylinux2014 container for glibc portability
if [[ "$target" == unknown-linux_* && "$use_container" != "no" ]]; then
  config="${REPO_ROOT}/ci/postgresql-release-config.json"
  container_image="$(jq -r --arg t "$target" '.portable.targets[$t].container // empty' "$config")"

  if [[ -z "$container_image" ]]; then
    echo "No container image configured for target $target in $config" >&2
    echo "Use --no-container to build directly on the host (not portable)" >&2
    exit 1
  fi

  runtime="$(detect_container_runtime || true)"
  if [[ -z "$runtime" ]]; then
    echo "Docker or Podman is required for portable Linux builds (glibc 2.17 baseline)" >&2
    echo "Install Docker/Podman, or use --no-container to build on the host (not portable)" >&2
    exit 1
  fi

  echo "Building inside ${container_image} via ${runtime} for glibc portability..."
  exec "$runtime" run --rm \
    -v "${REPO_ROOT}:${REPO_ROOT}" \
    -w "${REPO_ROOT}" \
    "$container_image" \
    bash -c "
      set -euo pipefail
      yum install -y -q epel-release >/dev/null 2>&1
      yum install -y -q bison ccache diffutils file findutils flex gcc gcc-c++ gettext-devel git gzip jq libicu-devel make openldap-devel patch patchelf perl readline-devel tar unzip which xz zlib-devel zip >/dev/null 2>&1
      chmod +x scripts/ci/*.sh scripts/*.sh
      scripts/ci/build_portable_postgresql.sh --target '$target' $(for a in "${passthrough_args[@]}"; do printf '%q ' "$a"; done)
    "
fi

exec "${SCRIPT_DIR}/ci/build_portable_postgresql.sh" --target "$target" "${passthrough_args[@]}"
