#!/usr/bin/env bash
# health-check.sh — run on the VM to see if the system recovered
# from a previous experiment. No restart needed if everything is green.
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
ok=0; warn=0; fail=0

check() {
  local label="$1" result="$2"
  if [ "$result" = "ok" ]; then
    echo -e "  ${GRN}✓${NC} $label"
    ok=$((ok+1))
  elif [ "$result" = "warn" ]; then
    echo -e "  ${YEL}!${NC} $label"
    warn=$((warn+1))
  else
    echo -e "  ${RED}✗${NC} $label"
    fail=$((fail+1))
  fi
}

echo "═══ 1. Chaos Mesh: any active experiments? ═══"
ACTIVE=$(kubectl -n chaos-mesh get podchaos,networkchaos,stresschaos -o name 2>/dev/null | wc -l)
if [ "$ACTIVE" -eq 0 ]; then
  check "No active chaos experiments" ok
else
  check "${ACTIVE} chaos object(s) still present — delete them first" fail
  echo "       kubectl -n chaos-mesh delete podchaos,networkchaos,stresschaos --all"
fi

echo ""
echo "═══ 2. Open5GS pods ═══"
for NF in amf smf upf; do
  STATUS=$(kubectl -n open5gs get pods -l app.kubernetes.io/name=${NF} \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
  READY=$(kubectl -n open5gs get pods -l app.kubernetes.io/name=${NF} \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  RESTARTS=$(kubectl -n open5gs get pods -l app.kubernetes.io/name=${NF} \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
  if [ "$STATUS" = "Running" ] && [ "$READY" = "true" ]; then
    check "${NF}: Running, ready (restarts: ${RESTARTS})" ok
  else
    check "${NF}: status=${STATUS}, ready=${READY}, restarts=${RESTARTS}" fail
  fi
done

echo ""
echo "═══ 3. UERANSIM ═══"
GNB_READY=$(kubectl -n open5gs get pods -l app.kubernetes.io/name=ueransim-gnb \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [ "$GNB_READY" = "true" ]; then
  check "gNB pod ready" ok
else
  check "gNB pod not ready" fail
fi

UE_POD=$(kubectl -n open5gs get pods -l app.kubernetes.io/name=ueransim-gnb-ues \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$UE_POD" ]; then
  # Fallback: find any pod with "ues" in the name
  UE_POD=$(kubectl -n open5gs get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep ues | head -1)
fi
if [ -n "$UE_POD" ]; then
  TUN_OUT=$(kubectl -n open5gs exec "$UE_POD" -- ip link show uesimtun0 2>&1 || true)
  if echo "$TUN_OUT" | grep -q "UP"; then
    check "UE tunnel (uesimtun0) up in pod ${UE_POD}" ok
  else
    check "UE tunnel (uesimtun0) missing — UE may need a restart" warn
  fi
else
  check "No UE pod found" fail
fi

echo ""
echo "═══ 4. Data-plane ping (UE → n6-server) ═══"
# n6-server is a deployment without a Service, so get the pod IP directly
N6_IP=$(kubectl -n open5gs get pods -l app=n6-server \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [ -z "$N6_IP" ]; then
  # Fallback: find by name pattern
  N6_POD=$(kubectl -n open5gs get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep n6-server | head -1)
  if [ -n "$N6_POD" ]; then
    N6_IP=$(kubectl -n open5gs get pod "$N6_POD" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
  fi
fi
if [ -n "$UE_POD" ] && [ -n "$N6_IP" ]; then
  PING=$(kubectl -n open5gs exec "$UE_POD" -- \
    ping -I uesimtun0 -c 3 -W 2 "$N6_IP" 2>/dev/null | tail -1 || echo "fail")
  if echo "$PING" | grep -q "min/avg/max"; then
    AVG=$(echo "$PING" | awk -F'/' '{print $5}')
    check "Ping to n6-server OK (avg ${AVG} ms)" ok
  else
    check "Ping to n6-server (${N6_IP}) failed" fail
  fi
else
  check "Cannot test ping (UE_POD=${UE_POD:-missing}, N6_IP=${N6_IP:-missing})" warn
fi

echo ""
echo "═══ 5. Prometheus scrape targets ═══"
TARGETS=$(curl -s localhost:9090/api/v1/targets 2>/dev/null)
if [ -n "$TARGETS" ]; then
  DOWN=$(echo "$TARGETS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
down=[t['labels'].get('nf','?') for t in d.get('data',{}).get('activeTargets',[]) if t['health']!='up']
print(len(down), ' '.join(down))
" 2>/dev/null || echo "? error")
  COUNT=$(echo "$DOWN" | awk '{print $1}')
  if [ "$COUNT" = "0" ]; then
    check "All Prometheus targets up" ok
  else
    check "Prometheus targets down: ${DOWN}" warn
  fi
else
  check "Cannot reach Prometheus at localhost:9090" warn
fi

echo ""
echo "═══════════════════════════════════════════"
echo -e "Result: ${GRN}${ok} ok${NC}, ${YEL}${warn} warn${NC}, ${RED}${fail} fail${NC}"
if [ "$fail" -eq 0 ] && [ "$warn" -eq 0 ]; then
  echo -e "${GRN}System is healthy — no restart needed.${NC}"
elif [ "$fail" -eq 0 ]; then
  echo -e "${YEL}Mostly fine, check the warnings above.${NC}"
else
  echo -e "${RED}Issues found — see above. You may need to restart RAN or clean up chaos objects.${NC}"
fi
