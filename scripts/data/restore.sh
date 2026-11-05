# Step 2, plan §10 step 8: the dump into RDS's `ringee` database, as ringee_app
# (so it owns every object, as with the app's own migrations). It never loads
# over existing tables: after a rehearsal, wipe first.
tables=$(public_tables)
if [ "$tables" != 0 ]; then
  echo "restore: ringee already has $tables tables; not restoring over them (prod-data.py wipe after a rehearsal)"
  exit 3
fi

start=$(now)
aws s3 cp "$(s3 .dump)" /tmp/ringee.dump --only-show-errors
downloaded=$(now)

# A non-superuser can't create these, and the app uses none of them: Railway's
# monitoring extensions, publications, and the public schema RDS already has.
pg_restore --list /tmp/ringee.dump >/tmp/toc.all
skip='^[0-9]+; [0-9]+ [0-9]+ ((EXTENSION - |COMMENT - EXTENSION )(pgaudit|pg_stat_statements)|(SCHEMA - |COMMENT - SCHEMA )public|PUBLICATION|SUBSCRIPTION)( |$)'
grep -Ev "$skip" /tmp/toc.all >/tmp/toc
echo "restore: skipped entries:"
grep -E "$skip" /tmp/toc.all >/tmp/toc.skipped || true
sed 's/^/  /' /tmp/toc.skipped
[ -s /tmp/toc.skipped ] || echo "  none"

PGOPTIONS='-c maintenance_work_mem=256MB' pg_restore --use-list=/tmp/toc --no-owner --no-privileges \
  --exit-on-error --jobs=4 --dbname="$PG_URL_APP" /tmp/ringee.dump
restored=$(now)
vacuumdb --analyze-only --schema=public --jobs=4 --quiet --dbname="$PG_URL_APP"
analyzed=$(now)

echo "restore: download $((downloaded - start)) s, pg_restore $((restored - downloaded)) s, analyze $((analyzed - restored)) s"
echo "restore: done, $(public_tables) tables"
