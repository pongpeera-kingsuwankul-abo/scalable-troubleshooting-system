#!/usr/bin/env bash
# export-prom.sh — dump Prometheus data to CSV
#
# Usage:
#   ./export-prom.sh [minutes_back] [step_seconds]
#       e.g. ./export-prom.sh 60 1        (last 60 min, 1s resolution)
#
#   ./export-prom.sh --from "HH:MM" --to "HH:MM" [step_seconds]
#       e.g. ./export-prom.sh --from "18:00" --to "18:05" 1
#       Times are today in the VM's local timezone.
#       Use "YYYY-MM-DD HH:MM" for a specific date:
#       ./export-prom.sh --from "2026-11-12 18:00" --to "2026-11-12 18:05" 1
#
# Requires: kubectl port-forward to prometheus already running,
#           or run this ON the VM where localhost:9090 works.
#
# Output: prom_export_<timestamp>.csv

PROM="http://localhost:9090"

# Parse arguments
if [ "$1" = "--from" ]; then
  FROM_STR="$2"
  TO_STR="$4"  # after --to
  STEP="${5:-1}"
  # If no date part, prepend today
  if [[ ! "$FROM_STR" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    FROM_STR="$(date +%Y-%m-%d) $FROM_STR"
  fi
  if [[ ! "$TO_STR" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    TO_STR="$(date +%Y-%m-%d) $TO_STR"
  fi
  START=$(date -d "$FROM_STR" +%s)
  NOW=$(date -d "$TO_STR" +%s)
  if [ "$NOW" -le "$START" ]; then
    echo "Error: --to must be after --from"
    exit 1
  fi
  MINUTES=$(( (NOW - START) / 60 ))
else
  MINUTES=${1:-60}
  STEP=${2:-1}
  NOW=$(date +%s)
  START=$((NOW - MINUTES * 60))
fi
TS=$(date +%Y%m%d_%H%M%S)
OUTFILE="prom_export_${TS}.csv"

# ── Queries ──────────────────────────────────────────────────────
# Each entry: "column_prefix|promql"
QUERIES=(
  # Open5GS native metrics (all that AMF/SMF/UPF expose)
  "core|{job=\"open5gs\"}"

  # Container CPU (rate over 30s)
  "cpu_rate|rate(container_cpu_usage_seconds_total{namespace=\"open5gs\"}[30s])"

  # Container memory RSS
  "mem_rss|container_memory_rss{namespace=\"open5gs\"}"

  # Pod ready (1/0)
  "ready|kube_pod_status_ready{namespace=\"open5gs\",condition=\"true\"}"

  # Container restarts
  "restarts|kube_pod_container_status_restarts_total{namespace=\"open5gs\"}"

  # Pod up (from the open5gs scrape job)
  "up|up{job=\"open5gs\"}"
)

echo "Exporting last ${MINUTES} min at ${STEP}s step → ${OUTFILE}"

TMPDIR=$(mktemp -d)
HEADER="timestamp"
FILE_IDX=0

for entry in "${QUERIES[@]}"; do
  PREFIX="${entry%%|*}"
  QUERY="${entry#*|}"
  FILE_IDX=$((FILE_IDX + 1))
  TMPFILE="${TMPDIR}/${FILE_IDX}.json"

  # URL-encode the query
  ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")

  HTTP=$(curl -s -o "$TMPFILE" -w "%{http_code}" \
    "${PROM}/api/v1/query_range?query=${ENCODED}&start=${START}&end=${NOW}&step=${STEP}")

  if [ "$HTTP" != "200" ]; then
    echo "  WARN: query '${PREFIX}' returned HTTP ${HTTP}, skipping"
    continue
  fi

  echo "  OK: ${PREFIX} ($(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(len(d.get('data',{}).get('result',[])), 'series')
" "$TMPFILE"))"
done

# ── Merge into one wide CSV ──────────────────────────────────────
python3 -I - "$TMPDIR" "$OUTFILE" "$START" "$NOW" "$STEP" <<'PYEOF'
import json, glob, sys, os, csv

tmpdir, outfile = sys.argv[1], sys.argv[2]
t_start, t_end, step = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

# Build a time index
timestamps = list(range(t_start, t_end + 1, step))
t_idx = {t: i for i, t in enumerate(timestamps)}
rows = len(timestamps)

columns = {}  # col_name -> [values]

for fpath in sorted(glob.glob(f"{tmpdir}/*.json")):
    with open(fpath) as f:
        data = json.load(f)
    if data.get("status") != "success":
        continue
    for series in data["data"]["result"]:
        metric = series["metric"]
        # Build a readable column name
        name = metric.get("__name__", "value")
        pod = metric.get("pod", metric.get("instance", ""))
        nf = metric.get("nf", "")
        if nf:
            col = f"{nf}_{name}"
        elif pod:
            # strip the hash suffix: open5gs-amf-7b4f.. -> amf
            parts = pod.replace("open5gs-", "").split("-")
            short = parts[0] if parts else pod
            col = f"{short}_{name}"
        else:
            col = name

        # Deduplicate column names
        base = col
        i = 2
        while col in columns:
            col = f"{base}_{i}"
            i += 1

        vals = [None] * rows
        for ts_val, val in series["values"]:
            idx = t_idx.get(int(ts_val))
            if idx is not None:
                vals[idx] = val
        columns[col] = vals

# Write CSV
col_names = sorted(columns.keys())
with open(outfile, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["timestamp"] + col_names)
    for i, t in enumerate(timestamps):
        row = [t] + [columns[c][i] if columns[c][i] is not None else "" for c in col_names]
        w.writerow(row)

print(f"Wrote {outfile}: {rows} rows × {len(col_names)+1} columns")
PYEOF

rm -rf "$TMPDIR"
echo "Done."
