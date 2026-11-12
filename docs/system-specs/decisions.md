# Decisions

## D1. Mask inside a throwaway Postgres, not in production

Production Postgres on Railway does not have the `anon` extension, and installing extensions in a customer's production database is a hard sell. The masker loads a plain dump into its own disposable Postgres, the way PostgreSQL Anonymizer's `/dump.sh` does. Its own script is used rather than `/dump.sh`, because `/dump.sh` sends all errors to `/dev/null`: a typo in a rule would silently publish unmasked data.
**Revisit** if dumps get too big for one container: mask in place on a read replica instead.

## D2. Dynamic masking role for the dump, not static `anonymize_database()`

Dumping through a `MASKED` role reads every column through its rule, and it is the documented anonymous-dump path. Static masking would rewrite every row first and double the disk writes.

## D3. Seeder reads production's bucket through plain variables

Every environment gets its own bucket, so references resolve to an empty bucket in a PR environment (verified on Railway). The only values copied unchanged into a PR environment are plain, non-sealed variables. Alternatives rejected:
- *Give the seeder production's `DATABASE_URL`* puts real data one query away from PR code.
- *Masker pushes into each PR environment* needs a workspace-wide API token. Railway has no read-only tokens.
- *Presigned URLs* expire after at most 7 days and would still need a plain variable to reach the PR.

Cost: PR code can read and overwrite the bucket, which only holds masked dumps. Railway does not deploy PRs from people outside the workspace.
**Revisit** when Railway supports cross-environment references or scoped bucket keys.

## D4. Seeder guard by environment name regex

Railway sets no variable that marks a PR environment. The default regex matches both name shapes Railway uses, `<project>-pr-<N>` and `pr-<hash>-<N>`. `production`, `staging` and `pr-preview` are skipped. `SOURCE_ENVIRONMENT` is skipped even if the regex matches.

## D5. Seed once, marker in the database comment

A redeploy must not wipe what reviewers created. A comment on the database doesn't show up in the app's schema, ORM introspection or migrations. It is written in the restore's own transaction.

## D6. Restore with `--clean --if-exists`

If the app's pre-deploy migrations ran first, the restore drops and recreates those objects. The database then matches production, including its migration history, so the app's next deploy applies only the PR's new migrations.

## D7. Strict detection on direct identifiers only

`anon.detect()` flags indirect identifiers too (`gender`, `job`, `lang`). Failing on those would block most schemas over false positives. `ALLOW_UNMASKED` is the escape hatch for false positives among the direct ones (for example `city`).

## D8. curl SigV4 instead of the AWS CLI

curl has signed S3 requests natively since 7.75. It keeps the image at the base image plus one small package. Path-style URLs work on Railway Buckets and on SeaweedFS in tests.

## D9. Bash, not Bun/TypeScript

The work is `pg_dump`, `psql` and one HTTP PUT. A runtime would add an install step and dependencies, and do nothing bash cannot.

## D10. The masker schedules itself instead of using a Railway cron

Template generation drops cron schedules, so a published template's masker would never run. `scripts/schedule.sh` masks once on deploy, then sleeps until `MASK_AT_UTC` each day. It exits at once outside `SOURCE_ENVIRONMENT`, so PR environments keep no idle masker. A failed run logs a warning and keeps the previous dump.

## D11. Users enter the database references on deploy

Railway refuses to publish a template whose variables reference a service outside it, so the template cannot default `SOURCE_DATABASE_URL` and `DATABASE_URL` to `${{Postgres.DATABASE_URL}}`. Both are required inputs, and their descriptions say what to enter. A reference typed at deploy time resolves like a default one. `.railway/railway.ts` keeps the references, because the demo project has its own `Postgres`.
