# Runs as the RDS master user (PGUSER/PGPASSWORD from the RDS-managed secret).
# Idempotent: creates what is missing and re-applies both passwords, so running
# it again after changing the generated secret rotates them.
set -eu
psql -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" -v temporal_pw="$TEMPORAL_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', role_name)
FROM unnest(ARRAY['ringee_app', 'temporal']) AS role_name
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name)\gexec

ALTER ROLE ringee_app WITH LOGIN PASSWORD :'app_pw';
ALTER ROLE temporal WITH LOGIN PASSWORD :'temporal_pw';

-- PostgreSQL 16+: creating a database owned by another role requires being
-- able to SET ROLE to it. Re-granting only prints a notice.
GRANT ringee_app TO CURRENT_USER;
GRANT temporal TO CURRENT_USER;

SELECT 'CREATE DATABASE ringee OWNER ringee_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'ringee')\gexec
SELECT 'CREATE DATABASE temporal OWNER temporal'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'temporal')\gexec
SELECT 'CREATE DATABASE temporal_visibility OWNER temporal'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'temporal_visibility')\gexec
SQL
echo "db-bootstrap: roles and databases are in place"
