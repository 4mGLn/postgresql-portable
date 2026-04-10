#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: discover_postgresql_releases.sh [--config <path>]

Reads tracked PostgreSQL majors from release config and prints a JSON object:
{
  "17": {"tag": "REL_17_5", "version": "17.5"},
  "18": {"tag": "REL_18_1", "version": "18.1"}
}
EOF
}

config="ci/postgresql-release-config.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      config="${2:-}"
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

if [[ ! -f "$config" ]]; then
  echo "Config file not found: $config" >&2
  exit 1
fi

repo="$(jq -r '.postgresql.upstream_git_repo // empty' "$config")"
if [[ -z "$repo" || "$repo" == "null" ]]; then
  echo "Missing .postgresql.upstream_git_repo in $config" >&2
  exit 1
fi

mapfile -t majors < <(jq -r '.postgresql.tracked_majors[]' "$config")
if [[ ${#majors[@]} -eq 0 ]]; then
  echo "No tracked majors configured in $config" >&2
  exit 1
fi

tag_refs="$(git ls-remote --tags --refs "$repo")"

out_file="$(mktemp)"
trap 'rm -f "$out_file" "${out_file}.new"' EXIT
jq -n '{}' > "$out_file"

for major in "${majors[@]}"; do
  latest_tag="$(
    printf '%s\n' "$tag_refs" \
      | awk '{print $2}' \
      | sed 's#refs/tags/##' \
      | grep -E "^REL_${major}_[0-9]+$" \
      | sort -V \
      | tail -n 1 || true
  )"

  if [[ -z "$latest_tag" ]]; then
    echo "Could not resolve latest release tag for PostgreSQL major $major" >&2
    exit 1
  fi

  patch="${latest_tag#REL_"${major}"_}"
  version="${major}.${patch}"

  jq \
    --arg major "$major" \
    --arg tag "$latest_tag" \
    --arg version "$version" \
    '. + {($major): {"tag": $tag, "version": $version}}' \
    "$out_file" > "${out_file}.new"
  mv "${out_file}.new" "$out_file"
done

cat "$out_file"
