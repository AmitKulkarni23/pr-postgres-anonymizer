/**
 * Railway infrastructure for PR Postgres Anonymizer.
 * Railway does not read this file on deploy; apply changes with
 * `railway config plan` then `railway config apply`.
 *
 * Postgres stands in for your app's database. The masker reads it in
 * production; in every PR environment the seeder fills that environment's
 * own copy of it with the masked dump.
 */
import { bucket, defineRailway, github, postgres, preserve, project, ref, service } from 'railway/iac'

const repo = github('AmitKulkarni23/pr-postgres-anonymizer', { branch: 'main' })
// Only the image matters to these services; docs and tests never redeploy them.
const build = { watchPatterns: ['Dockerfile', 'scripts/**'] }

export default defineRailway(() => {
  const db = postgres('Postgres')
  const dumps = bucket('pr-seed-dumps', { region: 'sjc' })

  const masker = service('masker', {
    source: repo,
    build,
    deploy: {
      // Masks on deploy, then daily at MASK_AT_UTC (default 03:00). A loop, not a Railway cron:
      // template generation drops cron schedules (decisions.md, D10). Exits at once outside production.
      startCommand: '/app/schedule.sh',
      restartPolicyType: 'ON_FAILURE',
    },
    // Only references and user input here. Template generation drops literal values, so
    // SOURCE_ENVIRONMENT, STRICT and MASK_AT_UTC use the scripts' defaults unless set by hand.
    env: {
      SOURCE_DATABASE_URL: db.env.DATABASE_URL,
      // SQL SECURITY LABEL rules, see demo/rules.sql. Set once in Railway (multiline).
      MASKING_RULES: preserve(),
      // Columns detection flags but that are not personal data: schema.table.column, comma-separated.
      ALLOW_UNMASKED: preserve(),
      S3_ENDPOINT: ref(dumps, 'ENDPOINT'),
      S3_BUCKET: ref(dumps, 'BUCKET'),
      S3_REGION: ref(dumps, 'REGION'),
      S3_ACCESS_KEY_ID: ref(dumps, 'ACCESS_KEY_ID'),
      S3_SECRET_ACCESS_KEY: ref(dumps, 'SECRET_ACCESS_KEY'),
    },
  })

  const seeder = service('seeder', {
    source: repo,
    build,
    deploy: {
      startCommand: '/app/seed.sh',
      // One-shot: restore and exit. A failure shows as a failed deploy, not a restart loop.
      restartPolicyType: 'NEVER',
    },
    env: {
      // This environment's own database: production here (skipped), the PR's copy in a PR environment.
      DATABASE_URL: db.env.DATABASE_URL,
      // Production's bucket as plain values, set by setup/link-seeder.sh. Not references:
      // each environment gets its own bucket, so a reference would point a PR environment
      // at an empty one. Not sealed: sealed variables are not copied into PR environments.
      S3_ENDPOINT: preserve(),
      S3_BUCKET: preserve(),
      S3_REGION: preserve(),
      S3_ACCESS_KEY_ID: preserve(),
      S3_SECRET_ACCESS_KEY: preserve(),
    },
  })

  return project('pr-postgres-anonymizer', { resources: [db, dumps, masker, seeder] })
})
