# Failure modes

Logs are one JSON object per line. Filter in Railway with `@event:<name>`.

| Event | Service | Meaning | Fix |
|---|---|---|---|
| `config_missing` | both | A required variable is empty | Set the named variable |
| `dump_failed` | masker | `pg_dump` of production failed | Check `SOURCE_DATABASE_URL` and that Postgres is up |
| `load_failed` | masker | The dump didn't load into the masking Postgres, usually an extension the image lacks (pgvector) | Not supported yet: README Limits |
| `rules_failed` | masker | `MASKING_RULES` has a SQL error (the psql line above names it) | Fix the rule. The previous dump is kept |
| `unmasked_columns` | masker | Strict mode found identifier columns with no rule | Add rules, or list them in `ALLOW_UNMASKED` if not personal data |
| `upload_failed` | masker | Bucket PUT failed | Check the bucket references on the masker |
| `mask_skipped` / `seed_skipped` | both | Guard: wrong environment, or already seeded | Expected |
| `db_unreachable` | seeder | PR Postgres not ready in 120 s | Redeploy the seeder |
| `download_failed` | seeder | No dump in the bucket the seeder points at | Run the masker once. If it has run, the seeder points at the wrong bucket: rerun `setup/link-seeder.sh` and check the values are plain, not references or sealed |
| `restore_failed` | seeder | Restore error, rolled back | Usually a schema that needs an extension. Read the psql error above it |

## Support runbook: "my PR environment's database is empty"

1. Open the seeder's logs in the PR environment. Railway shows "Completed" even when it failed.
2. `seed_skipped … does not match`: the environment name is unusual. Adjust `SEED_ENVIRONMENT_REGEX`.
3. `download_failed`: compare the seeder's `S3_BUCKET` in the PR environment with the masker's in production. If they differ, the seeder still has references: run `setup/link-seeder.sh`, then close and reopen the PR.
4. Seeder never deployed: Focused PR Environments skipped it. Deploy it from the canvas, or reference it from the app.
