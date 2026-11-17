#!/usr/bin/env python3
"""Score how much each KPI was affected by each fault, 1 (not at all) to 5 (completely).

Usage:
  python3 score_kpis.py run1.csv run2.csv ...      (CSV files written by export_window.py)

Writes two files in the current folder:
  kpi_fault_scores.csv         one row per KPI, one score column per fault
  kpi_fault_scores_detail.csv  one row per KPI and fault, with the numbers behind the score

Method (each run is compared with its own healthy phase):
  1. Normal range of a KPI = its lowest to highest value in the healthy phase, widened by a
     tolerance (half of that range, or 5% of the typical value if that is larger; never less
     than the noise floor: 1% of a CPU core, 1 MB of memory, 1 ms of ping time or jitter).
  2. Abnormal time = share of fault-phase seconds in which the KPI is outside the normal range
     or has stopped reporting. (CPU columns normally have gaps, so for them missing seconds
     only count when the column all but stops.)
  3. Score from abnormal time:  under 5% = 1, 5-25% = 2, 25-50% = 3, 50-75% = 4, 75% or more = 5.
  4. Size limit: if the KPI's average changed by less than a factor of 1.25 the score is at
     most 2; by less than a factor of 2, at most 3. (No limit when the KPI stopped reporting
     or was zero when healthy.)
Only uses the Python standard library.
"""
import csv, statistics as st, sys

JITTER_WINDOW = 10          # seconds of ping RTT used for the derived jitter KPI
# Changes smaller than these are treated as noise (prefix of the KPI name -> smallest change that counts)
NOISE_FLOOR = {"cpu.": 0.01,                 # 1% of one CPU core
               "mem.": 1e6,                  # 1 MB
               "process_resident_memory_bytes.": 1e6,
               "ping_rtt_ms.": 1.0,          # 1 ms
               "jitter_ms.": 1.0}
# Columns that normally have gaps (CPU is a 30 s rate): missing seconds only count when it all but stops
GAPPY = ("cpu.",)
PHASES = ("healthy", "fault", "recovered")

def num(x):
    return float(x) if x not in ("", None) else None

def load(path):
    rows = list(csv.DictReader(open(path, newline="")))
    cols = [c for c in rows[0].keys() if c not in ("timestamp", "fault_id", "severity", "phase")]
    data = {c: [num(r[c]) for r in rows] for c in cols}
    phase = [r["phase"] for r in rows]
    fault = next((r["fault_id"] for r in rows if r["fault_id"] not in ("", "none")), "none")
    # derived KPI: jitter = spread of the ping RTT over the last JITTER_WINDOW seconds
    for c in [c for c in cols if c.startswith("ping_rtt_ms.")]:
        name = "jitter_ms." + c.split(".", 1)[1]
        out = []
        for i in range(len(rows)):
            w = [v for v in data[c][max(0, i - JITTER_WINDOW + 1): i + 1] if v is not None]
            out.append(st.pstdev(w) if len(w) >= 3 else None)
        data[name] = out
    # derived KPI: restarted = 1 once the process start time differs from its healthy value
    for c in [c for c in cols if c.startswith("process_start_time_seconds.")]:
        base = [v for v, p in zip(data[c], phase) if p == "healthy" and v is not None]
        ref = st.median(base) if base else None
        data["restarted." + c.split(".", 1)[1]] = [
            None if (v is None or ref is None) else (0.0 if v == ref else 1.0) for v in data[c]]
        del data[c]
    return fault, phase, data

def score_kpi(values, phase, name=""):
    by = {p: [v for v, q in zip(values, phase) if q == p] for p in PHASES}
    H = [v for v in by["healthy"] if v is not None]
    F = [v for v in by["fault"] if v is not None]
    R = [v for v in by["recovered"] if v is not None]
    nH, nF = len(by["healthy"]), len(by["fault"])
    res = {"healthy_mean": st.mean(H) if H else None, "fault_mean": st.mean(F) if F else None,
           "recovered_mean": st.mean(R) if R else None}
    if not H or nF == 0:
        res.update(score=None, abnormal_pct=None, no_data_pct=None, change="", note="no healthy data to compare with")
        return res
    availH, availF = len(H) / nH, len(F) / nF
    tol = max(0.5 * (max(H) - min(H)), 0.05 * abs(st.median(H)),
              next((v for k, v in NOISE_FLOOR.items() if name.startswith(k)), 0.0))
    lo, hi = min(H) - tol, max(H) + tol
    a_out = sum(1 for v in F if v < lo or v > hi) / nF
    # seconds without data count as abnormal if the KPI normally reports every second,
    # or if it has all but stopped reporting
    counts = availF < 0.25 or (availH >= 0.95 and not name.startswith(GAPPY))
    a_miss = max(0.0, (1 - availF) - (1 - availH)) if counts else 0.0
    A = min(1.0, a_out + a_miss)
    base = 1 if A < 0.05 else 2 if A < 0.25 else 3 if A < 0.50 else 4 if A < 0.75 else 5
    mH, mF = res["healthy_mean"], res["fault_mean"]
    cap, change = 5, ""
    if mF is None:
        change = "no data"
    elif mH == 0:
        change = "0 -> %.4g" % mF if mF != 0 else "unchanged"
    elif mF == 0 or (mH > 0) != (mF > 0):
        change = "%.4g -> %.4g" % (mH, mF)
    else:
        fold = max(abs(mF) / abs(mH), abs(mH) / abs(mF))
        change = "%+.0f%%" % ((mF - mH) / abs(mH) * 100) if fold < 10 else "x%.0f" % (mF / mH) if mF > mH else "/%.0f" % (mH / mF)
        if not (a_miss > 0 and a_miss >= a_out):          # no size limit when it mostly stopped reporting
            cap = 2 if fold < 1.25 else 3 if fold < 2 else 5
    score = min(base, cap)
    if score == 1: note = "within normal range"
    elif a_miss > 0 and a_miss >= a_out: note = "stopped reporting for %.0f%% of the fault" % (a_miss * 100)
    elif score < base: note = "outside normal range %.0f%% of the fault, but the change is small" % (A * 100)
    else: note = "outside normal range %.0f%% of the fault" % (A * 100)
    res.update(score=score, abnormal_pct=round(A * 100, 1), no_data_pct=round((1 - availF) * 100, 1), change=change, note=note)
    return res

def group_of(k):
    nf = k.split(".")[1] if "." in k else ""
    if k.startswith(("ping_", "jitter_")): return "1 UE probe (ping)", "ue"
    if k.startswith("cpu."): return "5 Container CPU", nf
    if k.startswith("mem."): return "6 Container memory", nf
    if k.startswith(("up.", "scrape_")): return "4 Scrape health", nf
    if k.startswith(("process_", "restarted.")): return "3 Process stats (from the NF)", nf
    return "2 Open5GS counters and gauges", nf

def main(paths):
    runs = {}
    for p in paths:
        fault, phase, data = load(p)
        if fault in runs: sys.exit(f"two files for fault {fault}; give one run per fault")
        runs[fault] = {k: score_kpi(v, phase, k) for k, v in data.items()}
    faults = sorted(runs)
    kpis = sorted({k for r in runs.values() for k in r},
                  key=lambda k: (group_of(k)[0], -max((runs[f].get(k, {}).get("score") or 0) for f in faults), k))
    with open("kpi_fault_scores.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kpi", "group", "nf"] + faults + ["max_score"])
        for k in kpis:
            s = [runs[f].get(k, {}).get("score") for f in faults]
            g, nf = group_of(k)
            w.writerow([k, g[2:], nf] + ["" if x is None else x for x in s] + [max([x for x in s if x] or [""])])
    with open("kpi_fault_scores_detail.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["fault", "kpi", "group", "nf", "score", "healthy_mean", "fault_mean", "recovered_mean",
                    "change_of_mean", "abnormal_time_pct", "no_data_pct", "note"])
        fmt = lambda x: "" if x is None else ("%.6g" % x)
        for flt in faults:
            for k in kpis:
                r = runs[flt].get(k)
                if not r: continue
                g, nf = group_of(k)
                w.writerow([flt, k, g[2:], nf, "" if r["score"] is None else r["score"], fmt(r["healthy_mean"]),
                            fmt(r["fault_mean"]), fmt(r["recovered_mean"]), r["change"],
                            "" if r["abnormal_pct"] is None else r["abnormal_pct"],
                            "" if r["no_data_pct"] is None else r["no_data_pct"], r["note"]])
    print(f"{len(kpis)} KPIs x {len(faults)} faults -> kpi_fault_scores.csv, kpi_fault_scores_detail.csv")

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    main(sys.argv[1:])
