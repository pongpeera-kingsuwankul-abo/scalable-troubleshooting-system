#!/usr/bin/env bash
# poc-setup.sh - build the Open5GS PoC on a fresh Ubuntu 22.04 VM (k3s, 5G core, UERANSIM).
# Run as the normal user, not root:   poc-setup.sh
# Safe to re-run: finished steps are skipped. Prometheus and Chaos Mesh come later, after
# the metrics endpoints have been checked.
set -Eeuo pipefail

NS=open5gs
CORE_VERSION=2.2.0          # gradiant/open5gs; 2.2.9 only exists under another registry path
RAN_VERSION=0.2.6
VALUES=https://gradiant.github.io/5g-charts/docs/open5gs-ueransim-gnb

log() { echo "$(date +%H:%M:%S) == $*"; }
trap 'log "FAILED at line $LINENO"; kubectl -n $NS get pods 2>/dev/null || true' ERR

# 1. kernel modules (cloud-init loads them at boot; this is a re-check)
for m in sctp sch_netem ip_set xt_set; do
  sudo modprobe "$m" || log "WARNING: module $m missing: sudo apt -y install linux-modules-extra-$(uname -r)"
done

# 2. k3s without Traefik/servicelb (nothing here is exposed outside the VM)
if ! command -v k3s >/dev/null; then
  log "installing k3s"
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb" sh -
fi
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER" ~/.kube/config
export KUBECONFIG=~/.kube/config
grep -q KUBECONFIG ~/.bashrc || echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
# the node object appears a few seconds after k3s starts; `kubectl wait` fails if none exists yet
for i in $(seq 1 60); do
  [ -n "$(kubectl get nodes -o name 2>/dev/null)" ] && break
  sleep 3
done
kubectl wait --for=condition=Ready node --all --timeout=180s

# 3. Helm
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 4. 5G core only (no 4G functions)
kubectl get ns $NS >/dev/null 2>&1 || kubectl create ns $NS
if ! helm status open5gs -n $NS >/dev/null 2>&1; then
  log "installing Open5GS core $CORE_VERSION"
  helm install open5gs oci://registry-1.docker.io/gradiant/open5gs --version $CORE_VERSION -n $NS \
    --values $VALUES/5gSA-values.yaml --set webui.enabled=false
fi

# 5. MongoDB: on the earlier VM the deployment mixed a Bitnami layout (/bitnami/mongodb, uid 1001)
#    with the official mongo image (/data/db), so it crashed with "read-only directory".
#    Apply the fix only if MongoDB does not come up on its own.
if ! kubectl -n $NS rollout status deploy/open5gs-mongodb --timeout=120s; then
  log "MongoDB not ready: adapting the deployment to the official image"
  cat > /tmp/fix_mongo.py <<'PYEOF'
import json, sys
d = json.load(sys.stdin)
c = d["spec"]["template"]["spec"]["containers"][0]
c["image"] = "docker.io/mongo:5.0"
c["securityContext"] = {"runAsUser": 0, "runAsNonRoot": False}
for k in ("livenessProbe", "readinessProbe", "startupProbe"):
    c.pop(k, None)                      # probes call Bitnami scripts
mounts, found = [], False
for m in c.get("volumeMounts", []):
    if m["mountPath"] == "/bitnami/mongodb":
        m["mountPath"] = "/data/db"; m.pop("subPath", None); found = True
    elif m["mountPath"] == "/bitnami/scripts":
        continue
    mounts.append(m)
if not found:
    sys.exit("data mount not found - nothing changed")
c["volumeMounts"] = mounts
print(json.dumps(d))
PYEOF
  kubectl -n $NS get deploy open5gs-mongodb -o json | python3 /tmp/fix_mongo.py | kubectl replace -f -
  kubectl -n $NS rollout status deploy/open5gs-mongodb --timeout=180s
  kubectl -n $NS rollout restart deploy/open5gs-populate deploy/open5gs-udr deploy/open5gs-pcf
fi

# 6. wait until every NF is ready before the RAN starts (a gNB without an AMF only crash-loops)
for d in $(kubectl -n $NS get deploy -o name); do
  kubectl -n $NS rollout status "$d" --timeout=240s
done

# 7. resource limits on the NFs that get stressed (without them CPU/memory faults do nothing)
for nf in amf smf; do
  kubectl -n $NS set resources deploy/open5gs-$nf --requests=cpu=250m,memory=128Mi --limits=cpu=500m,memory=256Mi
done
kubectl -n $NS set resources deploy/open5gs-upf --requests=cpu=250m,memory=128Mi --limits=cpu=1,memory=256Mi
for nf in amf smf upf; do kubectl -n $NS rollout status deploy/open5gs-$nf --timeout=180s; done

# 8. RAN simulator: generates registrations and PDU sessions (no GNB_IP override: the chart
#    finds the gNB through its service name, and pod IPs change on every restart)
if ! helm status ueransim-gnb -n $NS >/dev/null 2>&1; then
  log "installing UERANSIM $RAN_VERSION"
  helm install ueransim-gnb oci://registry-1.docker.io/gradiant/ueransim-gnb --version $RAN_VERSION -n $NS \
    --values $VALUES/gnb-ues-values.yaml
fi
kubectl -n $NS rollout status deploy/ueransim-gnb --timeout=180s
ok=0
for i in $(seq 1 36); do
  if kubectl -n $NS exec deploy/ueransim-gnb-ues -- ip addr show uesimtun0 2>/dev/null | grep -q 'inet 10\.'; then
    ok=1; break
  fi
  sleep 5
done
if [ "$ok" != 1 ]; then
  log "UE did not get a PDU session within 3 minutes. Diagnostics:"
  kubectl -n $NS logs deploy/ueransim-gnb-ues --tail=30 || true
  kubectl -n $NS logs deploy/open5gs-amf --tail=30 || true
  kubectl -n $NS logs deploy/open5gs-udm --tail=20 || true
  exit 1
fi
log "UE has a session:"
kubectl -n $NS exec deploy/ueransim-gnb-ues -- ip addr show uesimtun0 | grep inet

# 9. the "internet" behind the UPF (target of the N6 fault)
kubectl -n $NS get deploy n6-server >/dev/null 2>&1 || \
  kubectl -n $NS create deployment n6-server --image=registry.k8s.io/pause:3.9
kubectl -n $NS rollout status deploy/n6-server --timeout=120s
N6_IP=$(kubectl -n $NS get pod -l app=n6-server -o jsonpath='{.items[0].status.podIP}')
log "pinging N6 server $N6_IP through the 5G core"
kubectl -n $NS exec deploy/ueransim-gnb-ues -- ping -c3 -W2 -I uesimtun0 "$N6_IP" || \
  log "WARNING: ping failed; check the UPF NAT: kubectl -n $NS exec deploy/open5gs-upf -- iptables -t nat -S"

log "done. N6 server IP: $N6_IP"
log "next: check the NF metrics endpoints (they must listen on 0.0.0.0:9090), then Prometheus and Chaos Mesh"
