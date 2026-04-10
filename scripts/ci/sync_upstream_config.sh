#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sync_upstream_config.sh [--config <path>]

Updates .postgresql.releases tags/versions in config by discovering latest upstream
PostgreSQL tags. Prints changed major versions as JSON array, for example:
["17","18"]
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

before="$(mktemp)"
discovered="$(mktemp)"
updated="$(mktemp)"
trap 'rm -f "$before" "$discovered" "$updated"' EXIT

cp "$config" "$before"
"${SCRIPT_DIR}/discover_postgresql_releases.sh" --config "$config" > "$discovered"

jq \
  --slurpfile discovered "$discovered" \
  '.postgresql.releases = (.postgresql.releases + $discovered[0])' \
  "$config" > "$updated"

mv "$updated" "$config"

jq -c \
  --slurpfile old "$before" \
  --slurpfile new "$config" \
  '
  [
    $new[0].postgresql.tracked_majors[] as $major
    | select(
        ($old[0].postgresql.releases[$major].tag // "") != ($new[0].postgresql.releases[$major].tag // "")
      )
    | $major
  ]
  ' < /dev/null
