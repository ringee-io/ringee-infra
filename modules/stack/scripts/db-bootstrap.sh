# Runs as the RDS master user (PGUSER/PGPASSWORD from the RDS-managed secret).
# Idempotent: creates what is missing and re-applies the three passwords, so
# running it again after changing a generated password rotates it.
set -eu
psql -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" -v temporal_pw="$TEMPORAL_DB_PASSWORD" \
  -v editor_pw="$EDITOR_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', role_name)
FROM unnest(ARRAY['ringee_app', 'temporal', 'ringee_editor']) AS role_name
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name)\gexec

ALTER ROLE ringee_app WITH LOGIN PASSWORD :'app_pw';
ALTER ROLE temporal WITH LOGIN PASSWORD :'temporal_pw';

-- PostgreSQL 16+: creating a database owned by another role requires being
-- able to SET ROLE to it. Re-granting only prints a notice.
GRANT ringee_app TO CURRENT_USER;
GRANT temporal TO CURRENT_USER;

-- People working on the data (DBeaver through scripts/db-tunnel.sh); no app
-- uses this role. Every session starts as ringee_app (SET ROLE below), so it
-- reads, changes and creates whatever the app can, and a table it creates
-- belongs to ringee_app, which later migrations can then alter. Nothing in the
-- Temporal databases.
ALTER ROLE ringee_editor WITH LOGIN PASSWORD :'editor_pw' CONNECTION LIMIT 10;
GRANT ringee_app TO ringee_editor;
ALTER ROLE ringee_editor SET ROLE ringee_app;
-- A person's transaction must never stall production. Left open in an editor,
-- it keeps its locks: an UPDATE blocks the app's writes to those rows, and an
-- ALTER TABLE waiting for a lock blocks every query queued behind it. A session
-- can raise any of these with SET.
ALTER ROLE ringee_editor SET idle_in_transaction_session_timeout = '5min';
ALTER ROLE ringee_editor SET lock_timeout = '10s';
ALTER ROLE ringee_editor SET statement_timeout = '2min';

SELECT 'CREATE DATABASE ringee OWNER ringee_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'ringee')\gexec
SELECT 'CREATE DATABASE temporal OWNER temporal'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'temporal')\gexec
SELECT 'CREATE DATABASE temporal_visibility OWNER temporal'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'temporal_visibility')\gexec
SQL
echo "db-bootstrap: roles and databases are in place"
