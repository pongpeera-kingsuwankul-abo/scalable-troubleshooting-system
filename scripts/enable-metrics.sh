#!/usr/bin/env bash
# enable-metrics.sh - turn on the Prometheus metrics server (0.0.0.0:9090) in AMF, SMF and UPF,
# then re-attach the RAN (restarting an NF drops the UE session) and test that each endpoint
# answers from another pod. Safe to re-run.
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS=open5gs
log() { echo "$(date +%H:%M:%S) == $*"; }

enable_metrics() {
  for nf in amf smf upf; do
    python3 - "$nf" <<'PYEOF'
import json, subprocess, sys, yaml
nf, ns = sys.argv[1], "open5gs"
cm = json.loads(subprocess.check_output(["kubectl", "-n", ns, "get", "cm", "open5gs-" + nf, "-o", "json"]))
keys = [k for k in cm["data"] if k.endswith((".yaml", ".yml"))]
if len(keys) != 1:
    sys.exit("%s: expected one yaml key in the ConfigMap, found %s" % (nf, list(cm["data"])))
key = keys[0]
cfg = yaml.safe_load(cm["data"][key])
if nf not in cfg or not isinstance(cfg[nf], dict):
    sys.exit("%s: top-level key '%s' not found in %s" % (nf, nf, key))
srv = [{"address": "0.0.0.0", "port": 9090}]
cur = cfg[nf].get("metrics")
if isinstance(cur, dict) and cur.get("server") == srv:
    print(nf, "metrics already enabled")
    sys.exit(0)
cfg[nf]["metrics"] = {"server": srv}
patch = {"data": {key: yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)}}
subprocess.check_call(["kubectl", "-n", ns, "patch", "cm", "open5gs-" + nf, "--type", "merge", "-p", json.dumps(patch)])
subprocess.check_call(["kubectl", "-n", ns, "rollout", "restart", "deploy/open5gs-" + nf])
print(nf, "metrics enabled in", key)
PYEOF
  done
}

enable_metrics
for nf in amf smf upf; do kubectl -n $NS rollout status deploy/open5gs-$nf --timeout=180s; done

# restarting the core dropped the UE session: gNB first, then the UEs
if kubectl -n $NS get deploy ueransim-gnb >/dev/null 2>&1; then
  log "re-attaching the RAN"
  kubectl -n $NS rollout restart deploy/ueransim-gnb
  kubectl -n $NS rollout status deploy/ueransim-gnb --timeout=180s
  kubectl -n $NS rollout restart deploy/ueransim-gnb-ues
  kubectl -n $NS rollout status deploy/ueransim-gnb-ues --timeout=180s
  ok=0
  for i in $(seq 1 36); do
    if kubectl -n $NS exec deploy/ueransim-gnb-ues -- ip addr show uesimtun0 2>/dev/null | grep -q 'inet 10\.'; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] && log "UE has a session again" || log "WARNING: UE has no session yet; check the UE log"
fi

# can another pod reach the metrics endpoints? (this is what Prometheus needs)
for nf in amf smf upf; do
  IP=$(kubectl -n $NS get pods -l app.kubernetes.io/name=$nf -o jsonpath='{.items[0].status.podIP}')
  log "$nf ($IP) metrics, first lines:"
  kubectl -n $NS run -q curl-$nf --image=curlimages/curl --restart=Never --rm -i --command -- \
    curl -s -m 3 "http://$IP:9090/metrics" | head -3 || true
done
log "done"
