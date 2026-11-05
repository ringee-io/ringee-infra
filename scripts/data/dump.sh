# Step 1, plan §10 step 8: Railway's database into the ops bucket. pg_dump
# runs here in AWS, so the data never crosses anyone's machine. The stats are
# taken right before and right after it: in cutover mode Railway must be
# stopped, and any difference means something still writes to it.
SRC=$(aws secretsmanager get-secret-value --secret-id "$SOURCE_SECRET" --query SecretString --output text)
case $SRC in
  postgres://* | postgresql://*) ;;
  *) echo "dump: $SOURCE_SECRET holds no database URL (prod-data.py fills it)"; exit 2 ;;
esac

if [ "${EMPTY_TARGET:-}" = yes ] && [ "$(public_tables)" != 0 ]; then
  echo "dump: RDS's ringee database already has tables; wipe it first, or the restore would refuse"
  exit 3
fi

# Who else is connected to Railway's database (counts by application, address
# and user; replication is not a client session). In cutover mode nothing may
# be: Api, Orchestrator and any other writer must be stopped first.
psql "$SRC" -X -t -A -F ' ' -v ON_ERROR_STOP=1 -c "SELECT count(*), coalesce(nullif(application_name, ''), '?'),
  coalesce(host(client_addr), 'local'), usename FROM pg_stat_activity
  WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() GROUP BY 2, 3, 4 ORDER BY 1 DESC" >/tmp/sessions.txt
echo "dump: other sessions on the source (count, application, address, user):"
sed 's/^/  /' /tmp/sessions.txt
[ -s /tmp/sessions.txt ] || echo "  none"
if [ "$MODE" = cutover ] && [ -s /tmp/sessions.txt ] && [ "${ALLOW_SESSIONS:-}" != yes ]; then
  echo "dump: FAILED, Railway's database still has sessions. Stop them, or rerun with --allow-sessions once you know they don't write."
  exit 5
fi

start=$(now)
stats "$SRC" >/tmp/before.tsv
pg_dump "$SRC" --format=custom --compress=6 --no-owner --no-privileges --file=/tmp/ringee.dump
dumped=$(now)
stats "$SRC" >/tmp/after.tsv
counted=$(now)
unset SRC

aws s3 cp /tmp/ringee.dump "$(s3 .dump)" --only-show-errors
aws s3 cp /tmp/before.tsv "$(s3 .before.tsv)" --only-show-errors
aws s3 cp /tmp/after.tsv "$(s3 .after.tsv)" --only-show-errors
uploaded=$(now)

tables=$(grep -c '^rows' /tmp/after.tsv || true)
rows=$(awk -F '\t' '$1 == "rows" { n += $3 } END { print n + 0 }' /tmp/after.tsv)
echo "dump: $tables tables, $rows rows, $(du -h /tmp/ringee.dump | cut -f1) compressed"
echo "dump: pg_dump $((dumped - start)) s, recount $((counted - dumped)) s, upload $((uploaded - counted)) s"
echo "dump: entries restore will skip (extensions it cannot create, publications):"
pg_restore --list /tmp/ringee.dump | grep -E '^[0-9]+; [0-9]+ [0-9]+ (EXTENSION|PUBLICATION|SUBSCRIPTION)( |$)' || echo "  none"

if ! cmp -s /tmp/before.tsv /tmp/after.tsv; then
  echo "dump: the source changed while it was dumped:"
  grep -vxFf /tmp/after.tsv /tmp/before.tsv | sed 's/^/  before: /' | head -30 || true
  grep -vxFf /tmp/before.tsv /tmp/after.tsv | sed 's/^/  after:  /' | head -30 || true
  if [ "$MODE" = cutover ]; then
    echo "dump: FAILED, something still writes to Railway's database. Stop it and dump again."
    exit 4
  fi
fi
echo "dump: done, $(s3 .dump)"
