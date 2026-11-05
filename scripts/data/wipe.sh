# After a rehearsal only: empty RDS's `ringee` database so the cutover restores
# into a clean one. prod-data.py refuses to send this when a service runs or
# when api.ringee.io already points at this stack.
echo "wipe: dropping $(public_tables) tables"
PGOPTIONS='-c client_min_messages=warning' psql "$PG_URL_APP" -X -q -v ON_ERROR_STOP=1 --single-transaction \
  -c 'DROP SCHEMA public CASCADE' -c 'CREATE SCHEMA public'
echo "wipe: done, $(public_tables) tables left"
