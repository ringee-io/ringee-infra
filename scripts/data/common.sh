# Shared by the ops-task steps of scripts/prod-data.py, which sends this file
# followed by one step (dump.sh, restore.sh, verify.sh or wipe.sh) as the
# task's `sh -c` command. Set by prod-data.py: KEY (the copy's S3 key prefix),
# MODE (rehearsal or cutover) and SOURCE_SECRET. Set by the task: OPS_BUCKET,
# PG_URL_APP (RDS as ringee_app) and PGSSLMODE=require.
set -eu

# The ops image is postgres:17-alpine: add the AWS CLI for S3 and Secrets Manager.
command -v aws >/dev/null 2>&1 || apk add --no-cache aws-cli >/dev/null

s3() { echo "s3://$OPS_BUCKET/$KEY$1"; }
now() { date +%s; }

# One line per fact, "kind<TAB>name<TAB>value", sorted, so both sides of the
# copy can be compared line by line: exact row count of every table, sequence
# positions, a digest of _prisma_migrations and counts of schema objects.
# Table names and numbers only: no customer data reaches the logs.
stats() {
  psql "$1" -X -q -t -A -F "$(printf '\t')" -v ON_ERROR_STOP=1 <<'SQL' | LC_ALL=C sort
SELECT format('SELECT %L, %L, count(*) FROM public.%I', 'rows', tablename, tablename)
FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename \gexec
SELECT 'seq', sequencename, coalesce(last_value::text, '-')
FROM pg_sequences WHERE schemaname = 'public';
SELECT 'prisma', 'migrations', count(*) || ' ' || coalesce(md5(string_agg(
  migration_name || '|' || checksum || '|' || (finished_at IS NOT NULL) || '|' || (rolled_back_at IS NOT NULL),
  ',' ORDER BY migration_name)), '-')
FROM public._prisma_migrations;
SELECT 'objects', kind, n::text FROM (
  SELECT 'tables' AS kind, count(*) AS n FROM pg_tables WHERE schemaname = 'public'
  UNION ALL SELECT 'indexes', count(*) FROM pg_indexes WHERE schemaname = 'public'
  UNION ALL SELECT 'constraints', count(*) FROM pg_constraint c
    JOIN pg_namespace s ON s.oid = c.connamespace WHERE s.nspname = 'public'
  UNION ALL SELECT 'enums', count(*) FROM pg_type t
    JOIN pg_namespace s ON s.oid = t.typnamespace WHERE s.nspname = 'public' AND t.typtype = 'e'
  UNION ALL SELECT 'functions', count(*) FROM pg_proc p
    JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'public'
  UNION ALL SELECT 'triggers', count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname = 'public' AND NOT t.tgisinternal
  UNION ALL SELECT 'views', count(*) FROM pg_views WHERE schemaname = 'public'
  UNION ALL SELECT 'large_objects', count(*) FROM pg_largeobject_metadata
) AS objects;
SQL
}

public_tables() {
  psql "$PG_URL_APP" -X -t -A -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'"
}
