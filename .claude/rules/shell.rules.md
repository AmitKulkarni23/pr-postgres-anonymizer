---
paths:
  - "scripts/**/*.sh"
  - "setup/**/*.sh"
  - "tests/**/*.sh"
---

# Shell Rules

- Scripts MUST be bash with `set -euo pipefail` (via `scripts/lib.sh` for the image scripts) and MUST pass shellcheck in CI.
- Logs MUST go through `log level event message` in `scripts/lib.sh`: one JSON line per event. Messages MUST NOT contain double quotes, credentials, connection strings or row data.
- Every failure MUST exit non-zero through `die event message`, naming what to fix.
- Required variables MUST be checked with `require` before first use.
- `psql` calls MUST use `-X -v ON_ERROR_STOP=1`. The restore MUST stay `--single-transaction`.
- The masker MUST upload as its last step. Nothing unmasked may be written outside its temp dir.
- The seeder's environment guard MUST run before any variable is read or any connection is made.
- No new tools in the image unless the base image plus curl cannot do the job.
