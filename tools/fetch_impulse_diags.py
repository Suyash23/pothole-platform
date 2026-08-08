#!/usr/bin/env python3
"""
Pull impulse-classifier telemetry (impulse_diag subcollection, v1.3.4) and
re-score the pothole / concrete-joint boundary against the driver's labels.

WHY THIS EXISTS
---------------
Before v1.3.4 the impulse thresholds could not be tuned offline at all. The
uploaded event log only records impulses that actually ALERTED, and a
cluster-path `rough_road` event carries just the triggering impulse's peak g —
no jerk, duration or rawZ. On the 7 drives ending 2026-08-04 that made 45 of
the 55 driver-labelled concrete joints impossible to replay through a modified
classifier, so DetectionConfig.potholeJointBoundary shipped on unvalidated
numbers.

Each impulse_diag row carries every quantity the classifier branched on, the
branch it took, and whether the driver actually saw an alert — so a proposed
boundary can be re-scored without another drive.

Run:  python3 fetch_impulse_diags.py [YYYY-MM-DD]   (defaults to today)
"""

import json
import sys
from collections import Counter, defaultdict
from datetime import datetime

try:
    import requests
except ImportError:
    print("ERROR: 'requests' not installed. Run:  pip install requests")
    sys.exit(1)

from fetch_firebase_analysis import API_KEY, BASE_URL, doc_to_dict, SESSION

# A correction is anchored to the alert's own ts (recorder.dart passes the
# DetectedEvent ts straight through), so the diag for the impulse behind it is
# within a sample or two. 3 s is generous without crossing to a neighbour.
PAIR_WINDOW_MS = 3000

# Keep in sync with DetectionConfig.potholeJointBoundary.
CURRENT_BOUNDARY = [(0, 50, 0.35), (50, 70, 0.45), (70, 95, 0.55), (95, 9999, 0.62)]

# Alternatives to score against the same labels.
CANDIDATES = {
    "current (shipped 2026-08-04)": CURRENT_BOUNDARY,
    "constant 0.35 (pre-v1.3.4)": [(0, 9999, 0.35)],
    "milder": [(0, 50, 0.35), (50, 70, 0.42), (70, 95, 0.48), (95, 9999, 0.52)],
    "steeper": [(0, 50, 0.35), (50, 70, 0.50), (70, 95, 0.62), (95, 9999, 0.72)],
}


def fetch_all_trips():
    trips, token = [], None
    while True:
        url = f"{BASE_URL}/trips?key={API_KEY}&pageSize=50"
        if token:
            url += f"&pageToken={token}"
        r = SESSION.get(url, timeout=30)
        if r.status_code != 200:
            print(f"ERROR {r.status_code}: {r.text[:200]}")
            sys.exit(1)
        data = r.json()
        for doc in data.get("documents", []):
            d = doc_to_dict(doc)
            d["_doc_name"] = doc.get("name", "")
            trips.append(d)
        token = data.get("nextPageToken")
        if not token:
            break
    return trips


def fetch_subcollection(doc_name, sub):
    """trips/{id}/{sub} → list of dicts. doc_name is the FULL resource name."""
    out, token = [], None
    while True:
        url = f"https://firestore.googleapis.com/v1/{doc_name}/{sub}?key={API_KEY}&pageSize=300"
        if token:
            url += f"&pageToken={token}"
        r = SESSION.get(url, timeout=60)
        if r.status_code != 200:
            return out
        data = r.json()
        for doc in data.get("documents", []):
            out.append(doc_to_dict(doc))
        token = data.get("nextPageToken")
        if not token:
            break
    return out


def local_date(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%Y-%m-%d")
    except Exception:
        return None


def boundary_for(curve, speed):
    for lo, hi, v in curve:
        if lo <= speed < hi:
            return v
    return curve[-1][2]


def classify(row, curve):
    """Re-run the branch decision for one diag row under a proposed boundary.

    Mirrors EventDetector._classifyImpulseBranch's ordering. The double-hit
    bump matcher is stateful and cannot be replayed from a single row, so rows
    the detector assigned to 'bump' are reported as-is rather than re-scored.
    """
    if row.get("branch") == "bump":
        return "bump"
    g = row.get("peak_g", 0.0)
    jerk = row.get("peak_jerk", 0.0)
    dur = row.get("duration_ms", 0)
    raw_z = row.get("raw_z", 0.0)
    b = boundary_for(curve, row.get("speed_kmh", 0.0))
    if g >= b and jerk >= 6.0 and raw_z >= row.get("pothole_z_threshold", 3.5):
        return "pothole"
    if g >= 0.20 and jerk <= 5.0 and 200 <= dur <= 750:
        return "speed_bump"
    if g >= 0.18 and g < b and jerk >= 3.0 and raw_z >= 3.0 and dur <= 100:
        return "concrete_joint"
    return "none"


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else datetime.now().strftime("%Y-%m-%d")
    print(f"Fetching trips for {target} …")
    trips = [t for t in fetch_all_trips() if local_date(t.get("startTimeMs")) == target]
    print(f"Trips on {target}: {len(trips)}\n")

    all_rows, all_labels = [], []
    for t in trips:
        doc_id = t["_doc_name"].split("/")[-1]
        batches = fetch_subcollection(t["_doc_name"], "impulse_diag")
        rows = [
            r
            for b in sorted(batches, key=lambda b: b.get("batchIndex", 0))
            for r in (b.get("rows") or [])
        ]
        events = fetch_subcollection(t["_doc_name"], "events")
        if not rows:
            print(f"=== Trip {doc_id}: no impulse_diag rows "
                  f"(pre-v1.3.4 recording, or upload incomplete) ===")
            continue

        # A reclassify writes TWO rows at one ts: the new label (isFalse=False)
        # and the old one negated (isFalse=True). Read the truth off those.
        by_ts = defaultdict(list)
        for e in events:
            if e.get("source") != "detector":
                by_ts[e["ts"]].append(e)
        labels = []
        for ts, group in by_ts.items():
            src = group[0].get("source")
            if src == "reclassify":
                new = [g["type"] for g in group if not g.get("is_false") and not g.get("isFalse")]
                if new:
                    labels.append((ts, new[0]))
            elif src == "confirm":
                labels.append((ts, group[0]["type"]))
            elif src == "false_alarm":
                labels.append((ts, "NOTHING"))

        print(f"=== Trip {doc_id} — {len(rows)} impulse candidates, "
              f"{len(labels)} driver labels ===")
        print("  branch taken:", dict(Counter(r.get("branch") for r in rows)))
        emitted = sum(1 for r in rows if r.get("emitted"))
        print(f"  reached the driver: {emitted}/{len(rows)}"
              f"  ({100*emitted/len(rows):.0f}%)")
        sup = Counter(r.get("suppressed_by") for r in rows if not r.get("emitted"))
        print("  suppressed by:", {k: v for k, v in sup.items() if k})
        none_n = sum(1 for r in rows if r.get("branch") == "none")
        print(f"  claimed by NO branch: {none_n} ({100*none_n/len(rows):.0f}%)"
              "  <- rising means thresholds have drifted apart")
        all_rows += rows
        all_labels += labels

        out = f"impulse_diags_{target}_{doc_id}.json"
        with open(out, "w") as f:
            json.dump({"diags": rows, "labels": labels}, f, indent=2)
        print(f"  Saved raw: {out}\n")

    if not all_rows or not all_labels:
        print("Nothing to re-score (need both diag rows and driver labels).")
        return

    # Pair each label to the impulse candidate that produced its alert.
    paired = []
    for ts, truth in all_labels:
        near = [r for r in all_rows
                if abs(r.get("ts", 0) - ts) <= PAIR_WINDOW_MS and r.get("emitted")]
        if not near:
            continue
        near.sort(key=lambda r: abs(r.get("ts", 0) - ts))
        paired.append((near[0], truth))

    print(f"\n=== BOUNDARY RE-SCORING ({len(paired)} labelled impulses) ===")
    if not paired:
        print("No label paired to an emitted impulse candidate.")
        return
    print(f"  {'curve':30} {'correct':>9}   by-speed accuracy")
    for name, curve in CANDIDATES.items():
        ok = sum(1 for r, truth in paired if classify(r, curve) == truth)
        buckets = []
        for lo, hi in [(0, 60), (60, 90), (90, 200)]:
            sub = [(r, t) for r, t in paired if lo <= r.get("speed_kmh", 0) < hi]
            if sub:
                k = sum(1 for r, t in sub if classify(r, curve) == t)
                buckets.append(f"{lo}-{hi}: {k}/{len(sub)}")
        print(f"  {name:30} {ok:>4}/{len(paired):<4}  " + "  ".join(buckets))
    print("\n  (speed_bump/joint gates above mirror the shipped constants — update")
    print("   CANDIDATES and classify() together when those change.)")


if __name__ == "__main__":
    main()
