# Step 3, plan §10 step 9: RDS against the stats taken around the dump. A fact
# the source didn't change during the dump must be identical on RDS. A row
# count or sequence that did change (rehearsal only: in cutover mode the dump
# already failed) must land between its two values. Any other difference fails.
aws s3 cp "$(s3 .before.tsv)" /tmp/before.tsv --only-show-errors
aws s3 cp "$(s3 .after.tsv)" /tmp/after.tsv --only-show-errors
stats "$PG_URL_APP" >/tmp/target.tsv

awk -F '\t' '
  FILENAME == ARGV[1] { before[$1 FS $2] = $3; keys[$1 FS $2] = 1; next }
  FILENAME == ARGV[2] { after[$1 FS $2] = $3; keys[$1 FS $2] = 1; next }
  { target[$1 FS $2] = $3; keys[$1 FS $2] = 1 }
  END {
    for (k in keys) {
      split(k, p, FS); b = before[k]; a = after[k]; t = target[k]
      if (!(k in target)) { print "verify: MISSING on RDS: " p[1] " " p[2]; bad++; continue }
      if (!(k in after)) { print "verify: EXTRA on RDS: " p[1] " " p[2] " = " t; bad++; continue }
      if (t == a && t == b) { same++; continue }
      if ((p[1] == "rows" || p[1] == "seq") && b ~ /^[0-9]+$/ && a ~ /^[0-9]+$/ && t ~ /^[0-9]+$/) {
        lo = (b + 0 < a + 0) ? b + 0 : a + 0
        hi = (b + 0 < a + 0) ? a + 0 : b + 0
        if (t + 0 >= lo && t + 0 <= hi) {
          print "verify: changed during the dump, consistent: " p[1] " " p[2] " (" b " -> " a ", RDS " t ")"
          drift++
          continue
        }
      }
      print "verify: WRONG: " p[1] " " p[2] " (source " b " -> " a ", RDS " t ")"
      bad++
    }
    printf "verify: %d identical, %d changed during the dump, %d wrong\n", same, drift, bad
    exit (bad > 0) ? 1 : 0
  }' /tmp/before.tsv /tmp/after.tsv /tmp/target.tsv
echo "verify: OK"
