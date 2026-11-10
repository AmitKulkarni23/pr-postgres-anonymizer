#!/usr/bin/env bash
# End-to-end test in Docker: a "production" Postgres with demo data, SeaweedFS (S3-compatible) as the
# bucket, the masker, then the seeder into an empty "PR" Postgres.
# Proves the masked data arrives complete and no original value leaks.
# Usage: bash tests/e2e.sh   (needs Docker; no network calls beyond image pulls)
set -euo pipefail
cd "$(dirname "$0")/.."

net=pr-seed-e2e
img=pr-seed:e2e
failures=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

cleanup() { docker rm -f e2e-prod e2e-pr e2e-s3 e2e-sched >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker build --platform linux/amd64 -q -t "$img" . >/dev/null
docker network create "$net" >/dev/null
for db in e2e-prod e2e-pr; do
  docker run -d --name "$db" --network "$net" -e POSTGRES_PASSWORD=pw postgres:17 >/dev/null
done
docker run -d --name e2e-s3 --network "$net" chrislusf/seaweedfs:3.97 server -s3 -s3.port=9000 -dir=/data >/dev/null

s3_env=(-e S3_ENDPOINT=http://e2e-s3:9000 -e S3_BUCKET=pr-seed -e S3_REGION=us-east-1
  -e S3_ACCESS_KEY_ID=e2e-key -e S3_SECRET_ACCESS_KEY=e2e-key)
run() { docker run --rm --platform linux/amd64 --network "$net" "${s3_env[@]}" "$@"; }
psql_on() { docker exec -i "$1" psql -U postgres -X -tA -v ON_ERROR_STOP=1 "${@:2}"; }

for db in e2e-prod e2e-pr; do
  until docker exec "$db" pg_isready -q -U postgres; do sleep 1; done
done
psql_on e2e-prod -q < demo/production.sql
until run "$img" bash -c 'source /app/lib.sh; s3 -X PUT "$(s3_url "")" >/dev/null' 2>/dev/null; do sleep 1; done

mask_env=(-e RAILWAY_ENVIRONMENT_NAME=production -e SOURCE_DATABASE_URL=postgres://postgres:pw@e2e-prod:5432/postgres
  -e "MASKING_RULES=$(cat demo/rules.sql)")
seed_env=(-e DATABASE_URL=postgres://postgres:pw@e2e-pr:5432/postgres)

echo "masker"
out=$(run "${mask_env[@]}" "$img" 2>&1) && rc=0 || rc=$?
check "should refuse to publish when detected columns have no rule" '[[ $rc -ne 0 && $out == *unmasked_columns*public.addresses.city* ]]'

out=$(run "${mask_env[@]}" -e MASKING_RULES="SECURITY LABEL FOR anon ON COLUMN public.nope.x IS 'MASKED WITH VALUE NULL';" "$img" 2>&1) && rc=0 || rc=$?
check "should fail loudly when a masking rule is invalid" '[[ $rc -ne 0 && $out == *rules_failed* ]]'

out=$(run "${mask_env[@]}" -e ALLOW_UNMASKED="public.addresses.city, public.addresses.country" "$img" 2>&1) && rc=0 || rc=$?
check "should publish when every detected column is masked or allowed" '[[ $rc -eq 0 && $out == *mask_published* ]]'
[[ $rc -eq 0 ]] || echo "$out"

out=$(run -e RAILWAY_ENVIRONMENT_NAME=shop-pr-7 "$img" 2>&1)
check "should do nothing when the masker runs outside production" '[[ $out == *mask_skipped* ]]'

echo "schedule"
out=$(run -e RAILWAY_ENVIRONMENT_NAME=shop-pr-7 "$img" /app/schedule.sh 2>&1)
check "should exit at once when the masker service runs outside production" '[[ $out == *mask_skipped* ]]'

docker run -d --name e2e-sched --platform linux/amd64 --network "$net" "${s3_env[@]}" "${mask_env[@]}" \
  -e ALLOW_UNMASKED="public.addresses.city,public.addresses.country" -e MASK_AT_UTC=03:00 "$img" /app/schedule.sh >/dev/null
for _ in $(seq 1 120); do docker logs e2e-sched 2>&1 | grep -q mask_next_run && break; sleep 1; done
out=$(docker logs e2e-sched 2>&1)
check "should mask once on deploy and schedule the next run when started in production" '[[ $out == *mask_published*mask_next_run*T03:00:00Z* ]]'
started=$SECONDS
docker stop -t 30 e2e-sched >/dev/null
check "should stop promptly when Railway sends SIGTERM" '(( SECONDS - started < 10 ))'
docker rm e2e-sched >/dev/null

echo "seeder"
for env in production staging pr-preview; do
  out=$(run "${seed_env[@]}" -e RAILWAY_ENVIRONMENT_NAME=$env "$img" /app/seed.sh 2>&1)
  check "should not touch the database when the environment is $env" '[[ $out == *seed_skipped* ]]'
done
check "should leave the database empty when skipped" '[[ $(psql_on e2e-pr -c "SELECT count(*) FROM pg_tables WHERE schemaname = '"'public'"'") == 0 ]]'

# An app that ran its migrations before the seeder: the masked dump replaces them.
psql_on e2e-pr -q -c "CREATE TABLE customers (id int)"
out=$(run "${seed_env[@]}" -e RAILWAY_ENVIRONMENT_NAME=pr-362a25-7 "$img" /app/seed.sh 2>&1) && rc=0 || rc=$?
check "should restore the masked dump when the environment is a PR environment" '[[ $rc -eq 0 && $out == *seed_done* ]]'
[[ $rc -eq 0 ]] || echo "$out"

check "should keep every customer when masking" '[[ $(psql_on e2e-pr -c "SELECT count(*) FROM customers") == 500 ]]'
check "should keep every order and its foreign key when masking" '[[ $(psql_on e2e-pr -c "SELECT count(*) FROM orders JOIN customers c ON c.id = orders.customer_id") == 2000 ]]'
check "should keep unmasked business columns when masking" '[[ $(psql_on e2e-pr -c "SELECT count(DISTINCT plan) FROM customers") == 3 ]]'
check "should keep sequences working when a reviewer inserts a row" 'psql_on e2e-pr -c "INSERT INTO customers (email, first_name, last_name) VALUES ('"'new@example.com'"', '"'A'"', '"'B'"')" >/dev/null'

pr_dump=$(docker exec e2e-pr pg_dump -U postgres --data-only)
for original in '@gmail.com' '@outlook.com' 'Garcia' 'Patel' '555-1' 'Market St' 'Called '; do
  check "should not leak '$original' when restored" '[[ $pr_dump != *"$original"* ]]'
done
check "should use reserved example.com emails when masking" '[[ $(psql_on e2e-pr -c "SELECT email FROM customers WHERE id = 1") == customer1@example.com ]]'

out=$(run "${seed_env[@]}" -e RAILWAY_ENVIRONMENT_NAME=shop-pr-7 "$img" /app/seed.sh 2>&1)
check "should not reseed when the seeder redeploys" '[[ $out == *"already seeded"* && $(psql_on e2e-pr -c "SELECT count(*) FROM customers") == 501 ]]'

echo
if [[ $failures -gt 0 ]]; then echo "$failures failed"; exit 1; fi
echo "all passed"
