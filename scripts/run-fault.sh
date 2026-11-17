#!/usr/bin/env bash
# run-fault.sh — one labelled fault run, end to end, with no manual timestamps.
#
#   ./run-fault.sh <FAULT_ID> [severity]        e.g.  ./run-fault.sh U5 low
#
# What it does:
#   1. Pre-checks: UE tunnel up, ping reaches n6-server through the UPF,
#      Prometheus reachable, no left-over chaos objects.
#   2. Starts a 1-per-second ping from the UE to n6-server (through the UPF).
#   3. Baseline -> applies the fault file -> hold -> removes it -> recovery.
#   4. Saves the text logs of every pod in the 5G namespace (the Open5GS functions,
#      the gNB and the UEs) and the Kubernetes events for the run window.
#   5. Exports the whole window with export_window.py (labels + ping columns).
#   6. Prints a per-phase summary and brings the UE back if the fault broke it.
#
# Each run gets its own folder under runs/ with: the CSV, ping_ue1.log, run.txt,
# logs/<pod>.log, k8s_events.csv, pods_start.txt and pods_end.txt.
#
# Timing in seconds can be overridden:
#   BASELINE=120 HOLD=120 RECOVER=120 ./run-fault.sh U8
# Keep HOLD no longer than the "duration" in the fault file.
#
# Expects in the same folder (or in ./faults and ./scripts):
#   <id>-*.yaml (e.g. u5-n6-loss-delay.yaml) and export_window.py
set -uo pipefail

FID="${1:?usage: ./run-fault.sh <FAULT_ID> [severity]   e.g. ./run-fault.sh U5 low}"
SEV="${2:-low}"
BASELINE="${BASELINE:-120}"; HOLD="${HOLD:-120}"; RECOVER="${RECOVER:-120}"
NS=open5gs
HERE="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(date -u +%H:%M:%S)Z] $*"; }
die() { echo "ABORT: $*" >&2; exit 1; }

# name, phase, IP of the newest non-terminating pod whose name starts with $1
pod_field() {  # $1 = name prefix, $2 = 1 (name) or 3 (ip)
  kubectl -n "$NS" get pods --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.podIP}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -v p="^$1-" -v f="$2" '$1 ~ p && $2=="Running" && $4=="" {v=$f} END{print v}'
}
ping_ok() {    # 3 pings from the UE through the tunnel; true if none lost
  kubectl -n "$NS" exec "$1" -- ping -I uesimtun0 -c 3 -W 2 "$2" 2>/dev/null | grep -q ', 0% packet loss'
}

# ── locate files ─────────────────────────────────────────────────────
fid_lc="$(echo "$FID" | tr 'A-Z' 'a-z')"
YAML="$(ls "$HERE"/"$fid_lc"-*.yaml "$HERE"/faults/"$fid_lc"-*.yaml 2>/dev/null | head -1)"
[ -n "$YAML" ] || die "no fault file named ${fid_lc}-*.yaml next to this script"
EXPORT="$(ls "$HERE"/export_window.py "$HERE"/scripts/export_window.py 2>/dev/null | head -1)"
[ -n "$EXPORT" ] || die "export_window.py not found next to this script"
case "$fid_lc" in a*) NF=amf ;; s*) NF=smf ;; *) NF=upf ;; esac

# ── 1. pre-checks ────────────────────────────────────────────────────
say "Pre-checks for $FID ($(basename "$YAML"))"
LEFT="$(kubectl get podchaos,networkchaos,stresschaos -A -o name 2>/dev/null | grep -c . || true)"
[ "${LEFT:-0}" -eq 0 ] || die "$LEFT chaos object(s) still exist. Remove them first:
  kubectl -n $NS delete podchaos,networkchaos,stresschaos --all"

# Let Chaos Mesh validate the fault file now, not after the baseline has been recorded
DRY="$(kubectl apply --dry-run=server -f "$YAML" 2>&1)" || die "Chaos Mesh rejects $(basename "$YAML"):
$DRY"

UE="$(pod_field ueransim-gnb-ues 1)"
[ -n "$UE" ] || die "no running UE pod (ueransim-gnb-ues-...)"
N6="$(pod_field n6-server 3)"
[ -n "$N6" ] || die "no running n6-server pod"
kubectl -n "$NS" exec "$UE" -- ip link show uesimtun0 >/dev/null 2>&1 \
  || die "UE tunnel uesimtun0 is missing. Restart the RAN (gNB first, then UEs) and retry."
ping_ok "$UE" "$N6" || die "ping from UE to n6-server ($N6) fails before the fault. Fix that first (./health-check.sh)."

PROM=""
CIP="$(kubectl -n monitoring get svc prometheus-server -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
for u in "http://localhost:9090" ${CIP:+"http://$CIP:80"}; do
  if curl -s --max-time 5 "$u/-/healthy" 2>/dev/null | grep -q Healthy; then PROM="$u"; break; fi
done
[ -n "$PROM" ] || die "Prometheus not reachable. Start the port-forward in tmux:
  kubectl -n monitoring port-forward svc/prometheus-server 9090:80"
UPCOUNT="$(curl -s --max-time 5 "$PROM/api/v1/query" --data-urlencode 'query=sum(up{job="open5gs"})' 2>/dev/null \
  | python3 -c 'import json,sys
try: print(int(float(json.load(sys.stdin)["data"]["result"][0]["value"][1])))
except Exception: print(0)')"
[ "$UPCOUNT" = "3" ] || die "Prometheus sees $UPCOUNT of 3 Open5GS targets up (AMF, SMF, UPF). Check localhost:9090/targets."
say "OK: UE=$UE  n6-server=$N6  Prometheus=$PROM"

# ── 2. start the ping ────────────────────────────────────────────────
RUN="${fid_lc}_${SEV}_$(date -u +%Y%m%d_%H%M%S)"
OUT="$HERE/runs/$RUN"; mkdir -p "$OUT"
PINGLOG="$OUT/ping_ue1.log"; CSV="$OUT/$RUN.csv"
LOGDIR="$OUT/logs"; mkdir -p "$LOGDIR"

# pod name and restart count of every pod in the namespace, one per line
pods_restarts() {
  kubectl -n "$NS" get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null
}

PING_PID=""; STREAM_PIDS=""
cleanup() {
  [ -n "$PING_PID" ] && kill "$PING_PID" 2>/dev/null
  [ -n "$STREAM_PIDS" ] && kill $STREAM_PIDS 2>/dev/null
  kubectl delete -f "$YAML" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT
trap 'echo; echo "Interrupted, removing the fault."; exit 130' INT TERM

START="$(now)"

# Follow every pod's log from now on. A pod that is killed or restarted during the run
# takes its log with it, so the live copy is the only way to keep what it wrote before.
kubectl -n "$NS" get pods -o wide > "$OUT/pods_start.txt" 2>&1
pods_restarts > "$OUT/.pods_start"
while read -r p _; do
  [ -n "$p" ] || continue
  kubectl -n "$NS" logs -f --timestamps --since-time="$START" "$p" > "$LOGDIR/$p.stream" 2>/dev/null &
  STREAM_PIDS="$STREAM_PIDS $!"
done < "$OUT/.pods_start"

kubectl -n "$NS" exec "$UE" -- ping -D -O -I uesimtun0 -i 1 "$N6" > "$PINGLOG" 2>&1 &
PING_PID=$!
sleep 4
grep -q 'time=' "$PINGLOG" || die "the background ping produced no replies; see $PINGLOG"

# ── 3. baseline -> fault -> recovery ─────────────────────────────────
say "Baseline: ${BASELINE}s of healthy traffic"
sleep "$BASELINE"
say "  last ping: $(tail -1 "$PINGLOG")"

say "Injecting $FID"
kubectl apply -f "$YAML" || die "kubectl apply failed"
ONSET="$(now)"
sleep 10
INJ="$(kubectl get -f "$YAML" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null || true)"
if [ "$INJ" = "True" ]; then
  say "  Chaos Mesh reports the fault as injected"
else
  say "  WARNING: Chaos Mesh does not report the fault as injected (AllInjected='$INJ')"
  kubectl describe -f "$YAML" 2>/dev/null | tail -12
fi
REST=$(( HOLD > 10 ? HOLD - 10 : 0 ))
say "Fault active: holding ${HOLD}s"
sleep "$REST"
say "  last ping: $(tail -1 "$PINGLOG")"

say "Removing the fault"
kubectl delete -f "$YAML" --ignore-not-found --timeout=60s >/dev/null 2>&1 \
  || say "  WARNING: removing the fault timed out; check: kubectl -n $NS get podchaos,networkchaos,stresschaos"
RECOVERED="$(now)"

say "Recovery: ${RECOVER}s"
sleep "$RECOVER"
say "  last ping: $(tail -1 "$PINGLOG")"
END="$(now)"
kill "$PING_PID" 2>/dev/null; PING_PID=""
sleep 5   # let Prometheus take its last scrapes

# ── 4. text logs and Kubernetes events ───────────────────────────────
say "Saving pod logs and Kubernetes events"
[ -n "$STREAM_PIDS" ] && kill $STREAM_PIDS 2>/dev/null; STREAM_PIDS=""
kubectl -n "$NS" get pods -o wide > "$OUT/pods_end.txt" 2>&1
pods_restarts > "$OUT/.pods_end"
# every pod that exists now: what its current container logged during the run
while read -r p _; do
  [ -n "$p" ] || continue
  kubectl -n "$NS" logs --timestamps --since-time="$START" "$p" > "$LOGDIR/$p.log" 2>/dev/null
done < "$OUT/.pods_end"
# the live copies: keep them only where they hold lines the pod can no longer give
for f in "$LOGDIR"/*.stream; do
  [ -e "$f" ] || continue
  p="$(basename "$f" .stream)"
  r0="$(awk -v p="$p" '$1==p{print $2+0}' "$OUT/.pods_start")"
  r1="$(awk -v p="$p" '$1==p{print $2+0; f=1} END{if(!f) print "gone"}' "$OUT/.pods_end")"
  if [ "$r1" = "gone" ]; then mv "$f" "$LOGDIR/$p.log"                      # pod was deleted
  elif [ "$r1" != "$r0" ]; then mv "$f" "$LOGDIR/$p.before-restart.log"     # container restarted
  else rm -f "$f"; fi
done
rm -f "$OUT/.pods_start" "$OUT/.pods_end"
find "$LOGDIR" -type f -empty -delete
# Kubernetes events (pod killed, restarted, unhealthy, fault applied ...) inside the run window
EVJSON="$(mktemp)"
kubectl get events -A -o json > "$EVJSON" 2>/dev/null
python3 - "$EVJSON" "$START" "$END" "$OUT/k8s_events.csv" <<'PYEOF'
import csv, json, sys
path, start, end, out = sys.argv[1:5]
try: items = json.load(open(path)).get("items", [])
except Exception: items = []
rows = []
for e in items:
    last = e.get("lastTimestamp") or e.get("eventTime") or e.get("metadata", {}).get("creationTimestamp")
    first = e.get("firstTimestamp") or e.get("eventTime") or last
    if not last: continue
    first, last = first[:19] + "Z", last[:19] + "Z"
    if last < start or first > end: continue
    o = e.get("involvedObject", {})
    rows.append([first, last, e.get("metadata", {}).get("namespace", ""), e.get("type", ""), e.get("reason", ""),
                 "%s/%s" % (o.get("kind", ""), o.get("name", "")), e.get("count") or 1,
                 " ".join((e.get("message") or "").split())])
rows.sort()
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["first_seen", "last_seen", "namespace", "type", "reason", "object", "count", "message"])
    w.writerows(rows)
print("  Kubernetes events in the window: %d" % len(rows))
PYEOF
rm -f "$EVJSON"
say "  pod log files: $(ls "$LOGDIR" | wc -l), lines: $(cat "$LOGDIR"/* 2>/dev/null | wc -l)"

# ── 5. export ────────────────────────────────────────────────────────
cat > "$OUT/run.txt" <<EOF
fault_id=$FID
severity=$SEV
fault_file=$(basename "$YAML")
start=$START
onset=$ONSET
recovered=$RECOVERED
end=$END
injected=$INJ
ue_pod=$UE
n6_ip=$N6
EOF
say "Exporting $START .. $END"
python3 "$EXPORT" --url "$PROM" --start "$START" --end "$END" \
  --fault "$FID" --severity "$SEV" --onset "$ONSET" --recovered "$RECOVERED" \
  --ping "$PINGLOG" --out "$CSV" || die "export failed; the ping log and times are kept in $OUT"

# ── 6. summary per phase ─────────────────────────────────────────────
python3 - "$CSV" "$NF" <<'PYEOF'
import csv, sys
path, nf = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(path)))
def mean(ph, col):
    v = [float(r[col]) for r in rows if r["phase"] == ph and r.get(col, "") != ""]
    return sum(v) / len(v) if v else None
def fmt(x, unit=""):
    return "   n/a" if x is None else f"{x:9.3f}{unit}"
print()
print(f"{'phase':<10} {'ping ms':>10} {'ping loss':>10} {'cpu.'+nf:>12} {'mem.'+nf+' MB':>12} {'up.'+nf:>8}")
for ph in ("healthy", "fault", "recovered"):
    ok = mean(ph, "ping_ok.ue1")
    loss = None if ok is None else (1 - ok) * 100
    mem = mean(ph, "mem." + nf)
    print(f"{ph:<10} {fmt(mean(ph,'ping_rtt_ms.ue1')):>10} {fmt(loss,'%'):>10} "
          f"{fmt(mean(ph,'cpu.'+nf)):>12} {fmt(None if mem is None else mem/1e6):>12} {fmt(mean(ph,'up.'+nf)):>8}")
print()
PYEOF
say "Data: $CSV"

# ── 7. leave the system healthy for the next run ─────────────────────
UE="$(pod_field ueransim-gnb-ues 1)"
if [ -n "$UE" ] && ping_ok "$UE" "$N6"; then
  say "System is healthy. Ready for the next run."
  exit 0
fi
say "UE traffic did not come back by itself (normal after a crash or freeze). Restarting the RAN."
for d in open5gs-amf open5gs-smf open5gs-upf; do
  kubectl -n "$NS" rollout status "deploy/$d" --timeout=180s >/dev/null 2>&1
done
kubectl -n "$NS" rollout restart deploy/ueransim-gnb >/dev/null
kubectl -n "$NS" rollout status deploy/ueransim-gnb --timeout=120s >/dev/null 2>&1
sleep 15
kubectl -n "$NS" rollout restart deploy/ueransim-gnb-ues >/dev/null
kubectl -n "$NS" rollout status deploy/ueransim-gnb-ues --timeout=120s >/dev/null 2>&1
for i in $(seq 1 12); do
  sleep 10
  UE="$(pod_field ueransim-gnb-ues 1)"; N6="$(pod_field n6-server 3)"
  if [ -n "$UE" ] && [ -n "$N6" ] && ping_ok "$UE" "$N6"; then
    say "RAN restarted, ping works again. Ready for the next run."
    exit 0
  fi
done
say "WARNING: ping still fails after the RAN restart. Run ./health-check.sh."
say "If the core pods are fine, restart the SMF and then the RAN again:"
say "  kubectl -n $NS rollout restart deploy/open5gs-smf"
exit 1
