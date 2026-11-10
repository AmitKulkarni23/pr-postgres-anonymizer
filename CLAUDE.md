# PR Postgres Anonymizer

A Railway template that fills every PR environment's Postgres with a masked copy of production. Built to be published to the Railway template marketplace.

## What It Does

A nightly **masker** cron in production runs `pg_dump`, loads the dump into a throwaway Postgres inside its own container and applies PostgreSQL Anonymizer masking rules. It then uploads the masked dump to a Railway Bucket. A **seeder** runs once when a PR environment is created. It restores that dump into the PR environment's own Postgres, then exits.

## Design Principles

- **Laziest correct solution**: two bash scripts on the official PostgreSQL Anonymizer image. No app server, no language runtime, no extra dependencies (S3 via curl's built-in SigV4).
- **Unmasked data never leaves the masker's container**: the upload is the masked dump only.
- **Fail closed**: strict mode refuses to publish with unmasked identifier columns. Any error stops the run, and the previous dump stays.
- **Never touch the wrong database**: the seeder runs only in environments named like Railway PR environments, never in `SOURCE_ENVIRONMENT`, and only once per environment.
- **Honest README**: how it works, the bucket trade-off, known limits.

## Tech Stack

- **Image**: `registry.gitlab.com/dalibo/postgresql_anonymizer:3.3.2` (Postgres 18) + curl
- **Scripts**: bash (`scripts/mask.sh`, `scripts/seed.sh`, shared `scripts/lib.sh`)
- **Storage**: Railway Bucket (S3-compatible), path-style URLs
- **Infrastructure as Code**: `.railway/railway.ts` (not the deprecated `railway.json`)
- **Tests**: `tests/e2e.sh` in Docker (Postgres 17 + SeaweedFS as S3)

## Folder Structure

```
pr-postgres-anonymizer/
├── .claude/rules/          # coding rules, loaded by path
├── .github/workflows/ci.yml # typecheck, shellcheck, e2e on every push and PR
├── .railway/railway.ts     # Railway IaC: Postgres, bucket, masker, seeder
├── scripts/                # copied into the image as /app
│   ├── lib.sh              # log, die, require, S3 helpers, dump key
│   ├── mask.sh             # masker: dump → mask → strict check → upload
│   └── seed.sh             # seeder: guard → wait → marker → download → restore
├── setup/link-seeder.sh    # one-time: copy production's bucket into the seeder as plain values
├── demo/                   # demo production data and its masking rules (tests and the demo project)
├── tests/e2e.sh            # end-to-end in Docker
├── docs/
│   ├── system-specs/       # architecture, decisions, failure modes
│   └── task-specs/         # TASK_INDEX.md lists tasks in order
├── Dockerfile
├── package.json            # railway (IaC SDK) + typescript, dev only
├── CLAUDE.md
└── README.md               # also the template's marketplace overview
```

## Rules

Coding rules live in `.claude/rules/` and load only when a matching file is touched:

- `shell.rules.md`: `scripts/`, `setup/`, `tests/` shell scripts
- `testing.rules.md`: `tests/`

## Environment Variables

See the README's Variables table. Secrets: the seeder's `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` are plain on purpose, because sealed variables are not copied into PR environments (decisions.md, D3). Never put any value in Git, `.railway/railway.ts` or chat.

## Commands

```bash
bun install
bun run typecheck                 # .railway/railway.ts
bash tests/e2e.sh                 # Docker end-to-end (about 2 minutes, amd64 image)
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x -e SC2016,SC2034 scripts/*.sh tests/*.sh setup/*.sh
railway config plan               # preview infra changes
railway config apply              # apply them
railway cron run --service masker --yes   # run the masker now
bash setup/link-seeder.sh         # after a fresh deploy or a bucket credential change
```

## Testing

- `tests/e2e.sh` runs the real image against a demo "production" database and a fake S3. It asserts strict mode, invalid rules, environment guards, row counts, foreign keys, sequences, idempotent reseeding, and that no original value appears in the PR database.
- GitHub Actions runs the typecheck, shellcheck and the e2e test on every push and PR.
- Railway itself (PR environment naming, per-environment buckets, cron) can only be tested on Railway: the demo project `pr-postgres-anonymizer` exists for that.
- Write the test first, see it fail, then implement.

## Environments

- **production**: the demo project. Postgres holds `demo/production.sql`, the masker runs nightly.
- **PR environments**: on. Each PR gets a seeded copy, deleted when the PR closes.

## Infrastructure as Code

All Railway configuration lives in `.railway/railway.ts`. No ClickOps after the first setup.

- **Deploy**: `railway config plan` before every `railway config apply`.
- **Never** change service settings in the Railway dashboard without updating `.railway/railway.ts`.
- Exceptions IaC cannot express: the PR environments toggle (project setting) and the seeder's `S3_*` values (`preserve()`, set by `setup/link-seeder.sh`).

## Browser Automation

**Do not run any browser automation (playwright-cli or claude-in-chrome) unless the user explicitly asks for it.**

## Specs and Tasks

- **System specs** (`docs/system-specs/`): `architecture.md`, `decisions.md`, `failure-modes.md`. Read before changing a script or the infra, and keep them current. Diagrams are Mermaid.
- **Tasks**: `docs/task-specs/TASK_INDEX.md` lists every task in order. When a task is done, strike its line through (`~~...~~`) in the same commit as its last change.
- Steps marked **asks the user** are hard stops: ask and wait.

## Git Conventions

- Commit messages must be at most 2 sentences/phrases long.
- Commit and push to GitHub after each meaningful file or logical unit of work is complete.
