#!/usr/bin/env bash
# Masker (cron): dump the source database, mask it inside a throwaway local
# Postgres with PostgreSQL Anonymizer, and upload the masked dump to the bucket.
# Production data never leaves this container unmasked.
source "$(dirname "$0")/lib.sh"

SOURCE_ENVIRONMENT=${SOURCE_ENVIRONMENT:-production}
if [[ "${RAILWAY_ENVIRONMENT_NAME:-}" != "$SOURCE_ENVIRONMENT" ]]; then
  # PR environments copy this cron too; there it has nothing to do.
  log info mask_skipped "environment ${RAILWAY_ENVIRONMENT_NAME:-unset} is not $SOURCE_ENVIRONMENT"
  exit 0
fi

require SOURCE_DATABASE_URL MASKING_RULES S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
started=$SECONDS
work=$(mktemp -d)
export PGDATA=$work/pgdata
chown postgres "$work"

local_pg() { gosu postgres "$@"; }
# Local psql: Unix socket only, stop at the first error.
lpsql() { local_pg psql -h "$work" -X -q -v ON_ERROR_STOP=1 "$@"; }

cleanup() { local_pg pg_ctl stop -m immediate >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

log info mask_started "dumping source database"
pg_dump "$SOURCE_DATABASE_URL" --format=plain --no-owner --no-privileges --file="$work/raw.sql" \
  || die dump_failed "pg_dump of SOURCE_DATABASE_URL failed"

# Disposable instance: no TCP, no fsync.
local_pg initdb --no-sync --auth=trust >/dev/null
local_pg pg_ctl start -w -l "$work/pg.log" -o "-c listen_addresses='' -c unix_socket_directories=$work -c fsync=off" >/dev/null

lpsql -d postgres -c "CREATE DATABASE src" \
  -c "ALTER DATABASE src SET session_preload_libraries = 'anon'"
lpsql -d src -c "CREATE EXTENSION anon" -c "SELECT anon.init()" >/dev/null
chmod 644 "$work/raw.sql"
lpsql -d src -f "$work/raw.sql" >/dev/null || die load_failed "source dump did not load into the masking database (an extension it needs may be missing)"
printf '%s\n' "$MASKING_RULES" > "$work/rules.sql"
chmod 644 "$work/rules.sql"
lpsql -d src -f "$work/rules.sql" || die rules_failed "MASKING_RULES has an error, see the line above"

# Strict mode: refuse to publish while a column that looks like a direct
# identifier (email, name, phone...) has no masking rule.
unmasked=$(lpsql -d src -tA -v allow="${ALLOW_UNMASKED:-}" <<'SQL'
SELECT n.nspname || '.' || c.relname || '.' || d.column_name
FROM anon.detect('en_US') d
JOIN pg_class c ON c.oid = d.table_name
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = d.column_name
WHERE d.direct
  AND c.relkind IN ('r', 'p')
  AND NOT EXISTS (
    SELECT 1 FROM pg_seclabel s
    WHERE s.provider = 'anon' AND s.objoid = c.oid AND s.objsubid = a.attnum
  )
  AND n.nspname || '.' || c.relname || '.' || d.column_name
      <> ALL (string_to_array(replace(:'allow', ' ', ''), ','))
ORDER BY 1;
SQL
)
if [[ -n "$unmasked" ]]; then
  if [[ "${STRICT:-true}" == "true" ]]; then
    die unmasked_columns "refusing to publish, no masking rule for: $(echo "$unmasked" | paste -sd, -). Add a rule, or list the column in ALLOW_UNMASKED if it is not personal data."
  fi
  log warn unmasked_columns "STRICT=false, publishing without rules for: $(echo "$unmasked" | paste -sd, -)"
fi

# Dump through a masked role: every read goes through the masking rules.
lpsql -d src \
  -c "CREATE ROLE dump_anon LOGIN" \
  -c "ALTER ROLE dump_anon SET anon.transparent_dynamic_masking = true" \
  -c "SECURITY LABEL FOR anon ON ROLE dump_anon IS 'MASKED'" \
  -c "GRANT pg_read_all_data TO dump_anon"
local_pg pg_dump -h "$work" -U dump_anon -d src --format=plain --no-owner --no-privileges \
  --no-security-labels --exclude-extension=anon --clean --if-exists \
  | gzip > "$work/masked.sql.gz"
[[ ${PIPESTATUS[0]} -eq 0 ]] || die masked_dump_failed "pg_dump through the masked role failed"

s3 --upload-file "$work/masked.sql.gz" "$(s3_url "$(dump_key)")" >/dev/null \
  || die upload_failed "could not upload to bucket $S3_BUCKET"
log info mask_published "uploaded $(dump_key) ($(du -h "$work/masked.sql.gz" | cut -f1)) in $((SECONDS - started))s"
