# Creates or upgrades both Temporal schemas. Connection settings come from the
# SQL_* variables of the task; run it before the server starts and after every
# Temporal upgrade (one minor version at a time).
set -eu
SCHEMA_DIR=/etc/temporal/schema/postgresql/v12
SQL_DATABASE=temporal temporal-sql-tool setup-schema -v 0.0
SQL_DATABASE=temporal temporal-sql-tool update-schema -d "$SCHEMA_DIR/temporal/versioned"
SQL_DATABASE=temporal_visibility temporal-sql-tool setup-schema -v 0.0
SQL_DATABASE=temporal_visibility temporal-sql-tool update-schema -d "$SCHEMA_DIR/visibility/versioned"
echo "temporal-schema: both schemas are current"
