#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Bash 4+ is required (found ${BASH_VERSION})" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage: run_local_build.sh --major <major> [--target <target>] [--jobs <n>] [--no-container] [additional build_portable_postgresql.sh args]

Builds the portable PostgreSQL archive for the current host platform.

Options:
  --target <target>  Override the auto-detected target (e.g. unknown-linux_x86_64,
                     windows_x86_64). The target must be supported by the host
                     environment — cross-compilation is not supported.
  --jobs <n>         Parallel make jobs (default: nproc / hw.ncpu)
  --no-ccache        Disable ccache even if it is available
  --no-container     Build directly on the host without a container (result is not
                     portable across glibc versions)

Supported targets and their required environments:
  unknown-linux_x86_64   Linux host or manylinux2014 container (default on Linux)
  windows_x86_64         MSYS2/MinGW-w64 on Windows (cannot cross-compile from Linux)
  macos_x86_64           macOS x86_64 host
  macos_aarch64          macOS Apple Silicon host

Windows builds from Linux: use GitHub Actions CI instead —
  gh workflow run release-and-publish.yml --field majors=<major> --field publish=false

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

detect_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    printf '4\n'
  fi
}

use_container="auto"
use_ccache="auto"
jobs="$(detect_jobs)"
target_override=""
passthrough_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-container)
      use_container="no"
      shift
      ;;
    --no-ccache)
      use_ccache="no"
      shift
      ;;
    --target)
      target_override="${2:-}"
      if [[ -z "$target_override" ]]; then
        echo "--target requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --jobs)
      jobs="${2:-}"
      if [[ -z "$jobs" ]]; then
        echo "--jobs requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      passthrough_args+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$target_override" ]]; then
  target="$target_override"
else
  target="$(detect_target || true)"
  if [[ -z "$target" ]]; then
    echo "Unsupported local host for portable build" >&2
    exit 1
  fi
fi

# ccache setup: persist the cache on the host under .cache/ccache-<target>
# so it survives across builds and container rebuilds.
ccache_dir="${REPO_ROOT}/.cache/ccache-${target}"
ccache_env_args=()
if [[ "$use_ccache" != "no" ]] && command -v ccache >/dev/null 2>&1; then
  mkdir -p "$ccache_dir"
  ccache_env_args=(
    -e "CCACHE_DIR=/ccache"
    -e "CC=ccache gcc"
    -e "CXX=ccache g++"
  )
  echo "ccache enabled (host cache: ${ccache_dir})"
else
  echo "ccache disabled"
fi

# On Linux, run inside the manylinux2014 container for glibc portability
if [[ "$target" == unknown-linux_* && "$use_container" != "no" ]]; then
  runtime="$(detect_container_runtime || true)"
  if [[ -z "$runtime" ]]; then
    echo "Docker or Podman is required for portable Linux builds (glibc 2.17 baseline)" >&2
    echo "Install Docker/Podman, or use --no-container to build on the host (not portable)" >&2
    exit 1
  fi

  local_image="postgresql-portable-build:local"
  dockerfile="${REPO_ROOT}/ci/Dockerfile.manylinux2014"

  echo "Building local container image from ${dockerfile}..."
  "$runtime" build -t "$local_image" -f "$dockerfile" "${REPO_ROOT}/ci"

  # Mount the host ccache directory into the container so the cache persists.
  ccache_mount_args=()
  if [[ ${#ccache_env_args[@]} -gt 0 ]]; then
    ccache_mount_args=(-v "${ccache_dir}:/ccache")
  fi

  echo "Building inside ${local_image} via ${runtime} for glibc portability..."
  exec "$runtime" run --rm \
    -v "${REPO_ROOT}:${REPO_ROOT}" \
    -w "${REPO_ROOT}" \
    "${ccache_mount_args[@]+"${ccache_mount_args[@]}"}" \
    "${ccache_env_args[@]+"${ccache_env_args[@]}"}" \
    "$local_image" \
    bash -c "
      set -euo pipefail
      $(if [[ ${#ccache_env_args[@]} -gt 0 ]]; then echo 'ccache --max-size=500M; ccache --zero-stats'; fi)
      chmod +x scripts/ci/*.sh scripts/*.sh
      scripts/ci/build_portable_postgresql.sh --target '$target' --jobs '$jobs' $(for a in "${passthrough_args[@]}"; do printf '%q ' "$a"; done)
      $(if [[ ${#ccache_env_args[@]} -gt 0 ]]; then echo 'echo "--- ccache stats ---"; ccache --show-stats'; fi)
    "
fi

# Bare-exec path (non-containerized or non-Linux)
if [[ "$use_ccache" != "no" ]] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="$ccache_dir"
  export CC="ccache gcc"
  export CXX="ccache g++"
  ccache --max-size=500M
  ccache --zero-stats
fi

exec "${SCRIPT_DIR}/ci/build_portable_postgresql.sh" --target "$target" --jobs "$jobs" "${passthrough_args[@]}"
