#!/usr/bin/env bash
# Masker service entrypoint: mask once on deploy, then every day at MASK_AT_UTC.
# A loop instead of a Railway cron because template generation drops cron
# schedules (decisions.md, D10). Outside SOURCE_ENVIRONMENT it exits at once,
# so PR environments do not keep an idle masker running.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${RAILWAY_ENVIRONMENT_NAME:-}" != "${SOURCE_ENVIRONMENT:-production}" ]]; then
  log info mask_skipped "environment ${RAILWAY_ENVIRONMENT_NAME:-unset} is not ${SOURCE_ENVIRONMENT:-production}"
  exit 0
fi

at=${MASK_AT_UTC:-03:00}
date -u -d "today $at" >/dev/null 2>&1 || die config_invalid "MASK_AT_UTC must be HH:MM, got $at"
trap 'exit 0' TERM INT

while true; do
  "$(dirname "$0")/mask.sh" || log warn mask_run_failed "keeping the previous dump, see the error above"
  now=$(date -u +%s)
  next=$(date -u -d "today $at" +%s)
  ((next > now)) || next=$(date -u -d "tomorrow $at" +%s)
  log info mask_next_run "next run at $(date -u -d "@$next" +%FT%TZ)"
  # Background sleep + wait so SIGTERM from a redeploy ends the wait at once.
  sleep $((next - now)) &
  wait $!
done
