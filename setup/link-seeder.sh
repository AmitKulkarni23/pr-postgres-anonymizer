#!/usr/bin/env bash
# One-time setup: copy production's bucket coordinates into the seeder as plain values.
#
# Why: every Railway environment gets its own bucket, so a reference like
# ${{pr-seed-dumps.BUCKET}} resolves to an empty bucket inside a PR environment.
# Plain (non-sealed) values are copied into PR environments unchanged, so the
# seeder there reads production's bucket, which only ever holds masked dumps.
# Do not seal them: sealed variables are not copied into PR environments.
#
# Usage: bash setup/link-seeder.sh [environment]   (run from a directory linked with `railway link`)
set -euo pipefail

env=${1:-production}
vars=$(railway variables --service masker --environment "$env" --kv)
args=()
for key in S3_ENDPOINT S3_BUCKET S3_REGION S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  value=$(grep "^$key=" <<<"$vars" | cut -d= -f2- || true)
  [[ -n "$value" ]] || { echo "masker has no $key in $env" >&2; exit 1; }
  args+=(--set "$key=$value")
done
railway variables --service seeder --environment "$env" "${args[@]}" --skip-deploys >/dev/null
echo "seeder in $env now points at bucket $(grep '^S3_BUCKET=' <<<"$vars" | cut -d= -f2-)"
