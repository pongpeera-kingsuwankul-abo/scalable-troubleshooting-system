#!/usr/bin/env python3
"""Export one time window from Prometheus into a wide CSV (one row per second).

Run on the VM while the Prometheus port-forward is running:
  kubectl -n monitoring port-forward svc/prometheus-server 9090:80   (in another tmux window)

Usage:
  python3 export_window.py --start 2026-11-12T07:11:00Z --end 2026-11-12T07:23:45Z \
      --fault A1 --severity low --onset 2026-11-12T07:16:18Z --recovered 2026-11-12T07:20:42Z \
      --out a1_low_run1.csv

Columns: timestamp, label columns (fault_id, severity, phase), then one column per metric series.
phase = healthy (before onset) / fault (onset..recovered) / recovered (after).
Only uses the Python standard library.
"""
import argparse, csv, json, re, sys, urllib.parse, urllib.request
from datetime import datetime, timezone

QUERIES = {
    # every Open5GS series (AMF, SMF, UPF counters and gauges, process_* stats)
    "o5gs": '{job="open5gs"}',
    # pod CPU (cores) and memory per core network function
    "cpu": 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="open5gs",container!=""}[30s]))',
    "mem": 'sum by (pod) (container_memory_working_set_bytes{namespace="open5gs",container!=""})',
}

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

def query_range(url, q, start, end, step):
    p = urllib.parse.urlencode({"query": q, "start": start, "end": end, "step": step})
    with urllib.request.urlopen(f"{url}/api/v1/query_range?{p}", timeout=60) as r:
        d = json.load(r)
    if d.get("status") != "success":
        sys.exit(f"Prometheus error for {q}: {d}")
    return d["data"]["result"]

def col_name(prefix, metric):
    m = dict(metric)
    name = m.pop("__name__", prefix)
    # keep the labels that tell series apart; drop noisy ones
    for k in ("job", "namespace", "endpoint", "service", "pod_template_hash", "node"):
        m.pop(k, None)
    pod, inst, nf = m.pop("pod", None), m.pop("instance", None), m.pop("nf", None)
    # name by network function, not by pod IP/hash, so a restarted pod stays in the same column
    if nf: who = nf
    elif pod and pod.startswith("open5gs-"): who = pod.split("-")[1]
    elif pod: who = re.sub(r"-[a-z0-9]{8,10}-[a-z0-9]{5}$", "", pod)   # drop deployment hash suffix
    else: who = inst or ""
    rest = ",".join(f"{k}={v}" for k, v in sorted(m.items()))
    if prefix in ("cpu", "mem"):
        name = f"{prefix}"
    return ".".join(x for x in (name, who, rest) if x)

def main():
    a = argparse.ArgumentParser()
    a.add_argument("--url", default="http://localhost:9090")
    a.add_argument("--start", required=True); a.add_argument("--end", required=True)
    a.add_argument("--step", default="1s")
    a.add_argument("--fault", default="none"); a.add_argument("--severity", default="")
    a.add_argument("--onset"); a.add_argument("--recovered")
    a.add_argument("--out", required=True)
    a.add_argument("--ping", action="append", default=[],
                   help="ping log made with 'ping -D -O' (repeat for each UE); adds ping_rtt_ms.<name> and ping_ok.<name>")
    o = a.parse_args()
    s, e = ts(o.start), ts(o.end)
    on = ts(o.onset) if o.onset else None
    rec = ts(o.recovered) if o.recovered else None

    cols, data = [], {}
    for prefix, q in QUERIES.items():
        res = query_range(o.url, q, s, e, o.step)
        print(f"{prefix}: {len(res)} series")
        for series in res:
            c = col_name(prefix, series["metric"])
            if c not in data:  # same name again (e.g. AMF pod replaced after a kill): merge into one column
                cols.append(c); data[c] = {}
            for t, v in series["values"]:
                t = int(float(t))
                if prefix == "cpu" or c not in data or t not in data[c]:
                    data[c][t] = v
                else:  # old and new pod overlap for a moment after a restart: keep the first value seen
                    pass
    for path in o.ping:
        name = re.sub(r"^ping_|\.log$", "", path.split("/")[-1])
        rtt, ok = {}, {}
        for line in open(path, errors="replace"):
            mt = re.match(r"\[(\d+(?:\.\d+)?)\]", line)
            if not mt: continue
            t = int(float(mt.group(1)))
            if not (s <= t <= e): continue
            mr = re.search(r"time=([\d.]+)", line)
            if mr: rtt[t] = mr.group(1); ok[t] = 1
            elif "no answer" in line or "Unreachable" in line: ok.setdefault(t, 0)
        for c, d in ((f"ping_rtt_ms.{name}", rtt), (f"ping_ok.{name}", ok)):
            cols.append(c); data[c] = {t: v for t, v in d.items()}
        print(f"ping {name}: {sum(ok.values())} replies, {list(ok.values()).count(0)} lost")
    times = sorted({t for d in data.values() for t in d})
    if not times:
        sys.exit("No data in that window. Check the times (UTC) and that the port-forward is running.")

    with open(o.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "fault_id", "severity", "phase"] + cols)
        for t in times:
            if on is None or t < on: ph = "healthy"
            elif rec is None or t <= rec: ph = "fault"
            else: ph = "recovered"
            fid = o.fault if ph == "fault" else "none"
            w.writerow([datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), fid,
                        o.severity if ph == "fault" else "", ph] + [data[c].get(t, "") for c in cols])
    print(f"Wrote {o.out}: {len(times)} rows x {len(cols) + 4} columns")

if __name__ == "__main__":
    main()
