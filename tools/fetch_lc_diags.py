#!/usr/bin/env python3
"""
Pull lane-change telemetry (lc_diag subcollection, v1.3.3) for recent trips
and print a tuning report.

The lane-change state machine logs one row per candidate manoeuvre that opened
phase 1 (plus turn-vetoes), with the measured value of every gate quantity.
This script pairs those rows with the driver's ground truth:

  • manual 'lane_change' marks (the new left-side button) → real lane changes;
    a nearby diag row shows WHICH gate rejected the real manoeuvre (or that no
    candidate ever opened — an entry-gate miss).
  • confirmed / false-alarm lane_change alerts → precision of the 'confirm'
    outcomes.

Run:  python3 fetch_lc_diags.py [YYYY-MM-DD]   (defaults to today)
"""

import json
import sys
from collections import Counter
from datetime import datetime

try:
    import requests
except ImportError:
    print("ERROR: 'requests' not installed. Run:  pip install requests")
    sys.exit(1)

from fetch_firebase_analysis import API_KEY, BASE_URL, doc_to_dict

# Pairing window between a ground-truth mark and a diag row. Manual marks are
# anchored ~1.4 s before the button press and the manoeuvre itself spans
# 2-4 s, so +/-10 s is generous without crossing into neighbouring manoeuvres.
PAIR_WINDOW_MS = 10_000


def fetch_all_trips():
    trips, token = [], None
    while True:
        url = f"{BASE_URL}/trips?key={API_KEY}&pageSize=50"
        if token:
            url += f"&pageToken={token}"
        r = requests.get(url, timeout=30)
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
    """Returns the list of documents in trips/{id}/{sub} (dicts)."""
    out, token = [], None
    while True:
        url = f"https://firestore.googleapis.com/v1/{doc_name}/{sub}?key={API_KEY}&pageSize=300"
        if token:
            url += f"&pageToken={token}"
        r = requests.get(url, timeout=30)
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


def fmt_ts(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%H:%M:%S")
    except Exception:
        return "?"


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else datetime.now().strftime("%Y-%m-%d")
    print(f"Fetching trips for {target} …")
    trips = [t for t in fetch_all_trips()
             if local_date(t.get("startTimeMs")) == target]
    print(f"Trips on {target}: {len(trips)}")

    for t in trips:
        doc_id = t["_doc_name"].split("/")[-1]
        diag_batches = fetch_subcollection(t["_doc_name"], "lc_diag")
        diags = [row for b in sorted(diag_batches,
                                     key=lambda b: b.get("batchIndex", 0))
                 for row in (b.get("rows") or [])]
        events = fetch_subcollection(t["_doc_name"], "events")
        lc_gt = [e for e in events
                 if e.get("type") == "lane_change" and e.get("source") != "detector"]

        print(f"\n=== Trip {doc_id} — {len(diags)} diag rows, "
              f"{len(lc_gt)} lane-change ground truths ===")
        if not diags and not lc_gt:
            continue

        print("Outcomes:", dict(Counter(d.get("outcome") for d in diags)))

        # Ground truth vs nearest diag row.
        for e in sorted(lc_gt, key=lambda e: e.get("ts") or 0):
            ts = int(e.get("ts") or 0)
            verdict = ("REAL (manual mark)" if e.get("source") == "manual"
                       else ("REAL (confirmed)" if e.get("source") == "confirm"
                             else ("NOT REAL (false alarm)" if e.get("is_false")
                                   else e.get("source"))))
            near = [d for d in diags
                    if abs(int(d.get("ts") or 0) - ts) <= PAIR_WINDOW_MS]
            near.sort(key=lambda d: abs(int(d.get("ts") or 0) - ts))
            print(f"\n  {fmt_ts(ts)}  {verdict}")
            if not near:
                print("    -> NO candidate within +/-10 s: entry gate never "
                      "opened (yaw stayed below the speed-scaled floor)")
            for d in near[:3]:
                dt = (int(d.get("ts") or 0) - ts) / 1000.0
                print(f"    -> {d.get('outcome'):20} dt={dt:+5.1f}s "
                      f"speed={d.get('speed_kmh', 0):5.1f}km/h "
                      f"peakYaw={d.get('peak_yaw_rads', 0):.3f} "
                      f"(entry {d.get('yaw_entry_rads', 0):.3f}) "
                      f"p1={d.get('phase1_heading_deg', 0):+5.1f}deg/"
                      f"{d.get('phase1_lat_m', 0):+4.1f}m "
                      f"p2={d.get('phase2_heading_deg', 0):+5.1f}deg/"
                      f"{d.get('phase2_lat_m', 0):+4.1f}m "
                      f"[{d.get('phase1_ms', 0)}/{d.get('crossover_ms', 0)}/"
                      f"{d.get('phase2_ms', 0)}ms]")

        out = f"lc_diags_{target}_{doc_id}.json"
        with open(out, "w") as f:
            json.dump({"diags": diags, "lane_change_gt": lc_gt}, f, indent=2)
        print(f"\n  Saved raw: {out}")


if __name__ == "__main__":
    main()
