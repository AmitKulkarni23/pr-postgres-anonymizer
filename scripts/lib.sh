# Shared helpers for mask.sh and seed.sh. Sourced, never run directly.
set -euo pipefail

# One JSON object per line, so Railway can filter on @level and @event.
# Messages must not contain double quotes or secrets.
log() {
  local level=$1 event=$2
  shift 2
  printf '{"level":"%s","event":"%s","msg":"%s"}\n' "$level" "$event" "$*"
}

die() {
  log error "$1" "${*:2}"
  exit 1
}

# Exit with a log line naming the first missing variable.
require() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die config_missing "$name is not set"
  done
}

# S3 over curl's built-in SigV4 signing, path-style URLs (Railway Buckets and MinIO both accept them).
s3_url() {
  printf '%s/%s/%s' "${S3_ENDPOINT%/}" "$S3_BUCKET" "$1"
}

s3() {
  curl --fail-with-body --silent --show-error --retry 3 \
    --aws-sigv4 "aws:amz:${S3_REGION:-auto}:s3" \
    --user "$S3_ACCESS_KEY_ID:$S3_SECRET_ACCESS_KEY" "$@"
}

# The object both services agree on.
dump_key() {
  printf '%s/latest.sql.gz' "${S3_PREFIX:-pr-seed}"
}
