#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: get_release_vars.sh --major <major> [--target <target>] [--config <path>]

Prints shell-safe KEY=VALUE lines for release build steps.
EOF
}

emit() {
  printf '%s=%q\n' "$1" "$2"
}

config="ci/postgresql-release-config.json"
major=""
target=""

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

if [[ -z "$major" ]]; then
  echo "--major is required" >&2
  exit 1
fi

if [[ ! -f "$config" ]]; then
  echo "Config file not found: $config" >&2
  exit 1
fi

tracked="$(jq -r --arg major "$major" '.postgresql.tracked_majors[] | select(. == $major)' "$config" || true)"
if [[ -z "$tracked" ]]; then
  echo "Major $major is not listed in .postgresql.tracked_majors" >&2
  exit 1
fi

pg_tag="$(jq -r --arg major "$major" '.postgresql.releases[$major].tag // empty' "$config")"
pg_version="$(jq -r --arg major "$major" '.postgresql.releases[$major].version // empty' "$config")"
upstream_repo="$(jq -r '.postgresql.upstream_git_repo // empty' "$config")"
source_url_template="$(jq -r '.postgresql.source_tarball_url_template // empty' "$config")"
release_name_prefix="$(jq -r '.portable.release_name_prefix // "postgresql-portable"' "$config")"
linux_baseline="$(jq -r '.portable.linux_baseline // empty' "$config")"
archive_format=""
runner=""
container=""

if [[ -z "$pg_tag" || -z "$pg_version" ]]; then
  echo "Missing PostgreSQL release data for major $major in $config" >&2
  exit 1
fi

if [[ -z "$upstream_repo" ]]; then
  echo "Missing .postgresql.upstream_git_repo in $config" >&2
  exit 1
fi

if [[ -z "$source_url_template" ]]; then
  echo "Missing .postgresql.source_tarball_url_template in $config" >&2
  exit 1
fi

if [[ -n "$target" ]]; then
  archive_format="$(jq -r --arg target "$target" '.portable.targets[$target].archive_format // empty' "$config")"
  runner="$(jq -r --arg target "$target" '.portable.targets[$target].runner // empty' "$config")"
  container="$(jq -r --arg target "$target" '.portable.targets[$target].container // empty' "$config")"
  if [[ -z "$archive_format" || -z "$runner" ]]; then
    echo "Target $target is not defined under .portable.targets in $config" >&2
    exit 1
  fi
fi

source_tarball_url="${source_url_template//\{version\}/$pg_version}"
release_tag="postgresql-${pg_version}"
release_title="PostgreSQL ${pg_version}"
source_archive_basename="postgresql-${pg_version}.tar.gz"

emit "PG_MAJOR" "$major"
emit "PG_TAG" "$pg_tag"
emit "PG_VERSION" "$pg_version"
emit "UPSTREAM_PG_REPO" "$upstream_repo"
emit "SOURCE_TARBALL_URL" "$source_tarball_url"
emit "SOURCE_ARCHIVE_BASENAME" "$source_archive_basename"
emit "RELEASE_NAME_PREFIX" "$release_name_prefix"
emit "RELEASE_TITLE" "$release_title"
emit "RELEASE_TAG" "$release_tag"
emit "LINUX_BASELINE" "$linux_baseline"

if [[ -n "$target" ]]; then
  archive_stem="${release_name_prefix}-${pg_version}-${target}"
  artifact_name="${release_name_prefix}-pg${major}-${target}"
  archive_basename="${archive_stem}.${archive_format}"
  emit "TARGET" "$target"
  emit "ARCHIVE_FORMAT" "$archive_format"
  emit "ARCHIVE_STEM" "$archive_stem"
  emit "ARCHIVE_BASENAME" "$archive_basename"
  emit "ARTIFACT_NAME" "$artifact_name"
  emit "TARGET_RUNNER" "$runner"
  emit "TARGET_CONTAINER" "$container"
fi
