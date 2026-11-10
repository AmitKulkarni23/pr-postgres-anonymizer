#!/usr/bin/env bash
# Seeder (runs once per deploy, then exits): restore the latest masked dump
# into this environment's Postgres. Only ever runs in PR environments.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

env_name=${RAILWAY_ENVIRONMENT_NAME:-}
# Railway names PR environments <project>-pr-<number>, or pr-<hash>-<number> when that name is taken.
# Railway sets no variable that marks a PR environment, so the name is the signal.
pattern=${SEED_ENVIRONMENT_REGEX:-(^|-)pr-([a-z0-9]+-)?[0-9]+$}
if [[ "$env_name" == "${SOURCE_ENVIRONMENT:-production}" ]] || ! [[ "$env_name" =~ $pattern ]]; then
  # Never touch production, staging or any environment not named like a PR environment.
  log info seed_skipped "environment ${env_name:-unset} does not match $pattern"
  exit 0
fi

require DATABASE_URL S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
started=$SECONDS

# A new PR environment starts its Postgres alongside this service.
for _ in $(seq 1 60); do
  pg_isready -q -d "$DATABASE_URL" && break
  sleep 2
done
pg_isready -q -d "$DATABASE_URL" || die db_unreachable "Postgres did not become ready in 120s"

# Seed once per environment, so a redeploy never wipes data a reviewer created.
marker=$(psql "$DATABASE_URL" -X -tA -c "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = current_database()")
if [[ "$marker" == pr-seed:* ]]; then
  log info seed_skipped "already seeded ($marker)"
  exit 0
fi

dump=$(mktemp)
trap 'rm -f "$dump"' EXIT
s3 --output "$dump" "$(s3_url "$(dump_key)")" >/dev/null \
  || die download_failed "no masked dump at $(dump_key) in bucket $S3_BUCKET yet. Run the masker once in production (railway cron run)."

# One transaction: a failed restore leaves the database as it was, and the marker is only set on success.
{
  gunzip -c "$dump"
  printf "DO \$\$ BEGIN EXECUTE format('COMMENT ON DATABASE %%I IS %%L', current_database(), 'pr-seed:' || now()); END \$\$;\n"
} | psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 --single-transaction >/dev/null \
  || die restore_failed "restoring the masked dump failed, database unchanged"

log info seed_done "restored $(dump_key) into ${env_name} in $((SECONDS - started))s"
