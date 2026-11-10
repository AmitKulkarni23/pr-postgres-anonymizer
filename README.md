# Deploy and Host PR Postgres Anonymizer with Railway

PR Postgres Anonymizer fills every Railway PR environment's Postgres with a masked copy of production. Each night a cron dumps production and masks emails, names, phones and addresses with PostgreSQL Anonymizer, then stores the dump in a Railway Bucket. Each new PR environment restores that dump. Reviewers get realistic data and no real customers.

## About Hosting PR Postgres Anonymizer

Railway PR environments copy your services, but their databases start empty. Copying production in is not safe, because preview URLs are public. This template adds two small services and a bucket next to your existing Postgres. The **masker** runs nightly in production. It runs `pg_dump`, loads the dump into a throwaway Postgres inside its own container, applies your masking rules and uploads the masked dump. Unmasked data never leaves that container. The **seeder** runs once when a PR environment is created. It downloads the masked dump and restores it into that PR environment's own Postgres, then exits. Strict mode refuses to publish while any column that looks like personal data has no masking rule.

## Common Use Cases

- Preview a PR against production-shaped data: real row counts, real foreign keys, real edge cases.
- Reproduce "works in prod, broken in preview" bugs without handing customer data to reviewers.
- Give contractors, design reviewers or QA a live preview that contains no personal data.
- Keep demo and preview environments from going stale: a fresh masked copy every night.

## Dependencies for PR Postgres Anonymizer Hosting

- A Railway project with a Postgres service, named `Postgres` by default.
- PR environments turned on: Project Settings → Environments → Enable PR Environments.

### Deployment Dependencies

- [PostgreSQL Anonymizer](https://postgresql-anonymizer.readthedocs.io/) 3.3.2, from the official Dalibo image on Postgres 18.
- [Railway PR environments](https://docs.railway.com/environments), [cron jobs](https://docs.railway.com/cron-jobs) and [Buckets](https://docs.railway.com/storage-buckets).

### Implementation Details

```
production                                     PR environment (pr-…-42)
┌──────────┐ pg_dump  ┌─────────────────────┐   ┌────────┐ restore ┌──────────┐
│ Postgres │ ───────▶ │ masker (cron 03:00) │   │ seeder │ ──────▶ │ Postgres │
└──────────┘          │ throwaway Postgres  │   └────────┘         │ (empty)  │
                      │ + anon masking rules│       ▲              └──────────┘
                      └─────────┬───────────┘       │ download
                                ▼ upload            │
                        Bucket: pr-seed/latest.sql.gz
```

Masking rules are plain SQL in the masker's `MASKING_RULES` variable:

```sql
SECURITY LABEL FOR anon ON COLUMN public.customers.email
  IS 'MASKED WITH FUNCTION pg_catalog.concat(''customer'', id, ''@example.com'')';
SECURITY LABEL FOR anon ON COLUMN public.customers.last_name
  IS 'MASKED WITH FUNCTION anon.dummy_last_name()';
```

See [`demo/rules.sql`](demo/rules.sql) for a full example and the [function reference](https://postgresql-anonymizer.readthedocs.io/en/stable/masking_functions/) for everything you can use.

### Why Deploy PR Postgres Anonymizer on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying PR Postgres Anonymizer on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.

## Setup

1. Deploy the template into the project that holds your production Postgres.
2. Paste your masking rules into the masker's `MASKING_RULES` variable.
3. Give the seeder production's bucket coordinates as **plain values**. Either run `bash setup/link-seeder.sh` from a directory linked to the project, or copy the five values from the bucket's Credentials tab into the seeder's `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`. Do not use references and do not seal them (see below).
4. Run the masker once: `railway cron run --service masker --yes`. If strict mode lists unmasked columns, add rules for them, or list them in `ALLOW_UNMASKED` if they are not personal data.
5. Open a PR. Its environment's Postgres is seeded within a minute.

### Why the seeder needs plain values

Every Railway environment gets its own bucket. A reference like `${{pr-seed-dumps.BUCKET}}` therefore resolves to a new, empty bucket inside a PR environment. Plain variables are copied into PR environments unchanged, so the seeder there still reads production's bucket. Sealed variables are not copied at all. The bucket only ever holds masked dumps. The trade-off: code in a PR environment can read and overwrite that bucket. Railway does not deploy PRs from people outside your workspace, which limits who could.

## Variables

**masker**

| Variable | Default | Description |
|---|---|---|
| `SOURCE_DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | Production database to dump. Read over the private network. |
| `MASKING_RULES` | required | `SECURITY LABEL FOR anon` rules, one per column (multiline SQL). |
| `ALLOW_UNMASKED` | empty | `schema.table.column` list that detection flags but that is not personal data. |
| `STRICT` | `true` | `false` publishes anyway and logs a warning listing the unmasked columns. |
| `SOURCE_ENVIRONMENT` | `production` | The only environment the masker runs in. |
| `S3_*` | bucket references | Bucket the masked dump is uploaded to. |

**seeder**

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | This environment's own database, the one to fill. |
| `S3_*` | set at setup | Production's bucket as plain values (setup step 3). |
| `SEED_ENVIRONMENT_REGEX` | `(^\|-)pr-([a-z0-9]+-)?[0-9]+$` | Environments the seeder may overwrite. Matches Railway's PR environment names only. |
| `SOURCE_ENVIRONMENT` | `production` | Never seeded, whatever the regex says. |

## Safety guarantees

- The seeder never runs in `SOURCE_ENVIRONMENT`, or in any environment whose name doesn't look like a PR environment (`staging` and `pr-preview` are skipped).
- A PR environment is seeded once. Redeploys keep whatever reviewers created. The marker is a comment on the database, so it doesn't appear in your schema.
- The restore runs in one transaction. If it fails, the database is left as it was.
- Strict mode is on by default. A bad rule, a missing extension or an unmasked column stops the run, and the previous dump stays in place.

## Limits

- Postgres only.
- The whole database is copied: no subsetting yet. The masker's container needs room for about two copies of your data.
- Extensions your production schema uses must exist in the Anonymizer image (Postgres 18 contrib). Otherwise the load fails loudly. pgvector is not included.
- Detection uses a dictionary of column names (`email`, `phone`, `last_name`…). It cannot see personal data in free text, JSON or oddly named columns. Review your schema, and mask free text whole.
- If your app runs migrations before the seeder finishes, the restore replaces them with production's schema. Redeploy the app after seeding to apply the PR's migrations on top.
- With Focused PR Environments, the seeder deploys only if it is a dependency of a changed service. Reference it from your app, or deploy it from the canvas.

## Development

```bash
bun install
bun run typecheck          # .railway/railway.ts
bash tests/e2e.sh          # Docker: masks a demo database and proves nothing leaks
railway config plan        # then railway config apply
```

Architecture, decisions and failure modes are in [`docs/system-specs/`](docs/system-specs/).
