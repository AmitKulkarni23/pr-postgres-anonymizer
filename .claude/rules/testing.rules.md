---
paths:
  - "tests/**"
---

# Testing Rules

- `tests/e2e.sh` MUST run the real image against real Postgres containers, with no network calls beyond image pulls.
- Test names MUST read `should <outcome> when <trigger>`.
- Every new guard or failure path in `scripts/` MUST get a check in `tests/e2e.sh`.
- Leak checks MUST search the PR database's full data dump for original values from `demo/production.sql`.
- Test data MUST look real (real-looking names, emails, phones), never `test` or `abc`.
- Tests MUST NOT use fixed sleeps to wait for results; poll a condition (`until …; do sleep 1; done`).
