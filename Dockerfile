# One image, two services: the masker (scripts/schedule.sh runs scripts/mask.sh daily) and the seeder (scripts/seed.sh).
# PostgreSQL Anonymizer on Postgres 18; pg_dump 18 can dump any older server.
FROM registry.gitlab.com/dalibo/postgresql_anonymizer:3.3.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/ /app/

# Replace the Postgres server entrypoint: these are one-shot jobs.
ENTRYPOINT []
CMD ["/app/schedule.sh"]
