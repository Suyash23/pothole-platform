#!/usr/bin/env python3
"""
Pull YESTERDAY's drive(s) from Firestore and save + summarize them.

Run locally (needs internet):
    pip install requests
    python3 fetch_yesterdays_drive.py

Outputs (in current dir):
    yesterdays_drive_YYYY-MM-DD.json   raw trip document(s) recorded yesterday
    yesterdays_drive_summary.txt       human-readable per-trip summary

Reuses the analysis helpers from fetch_firebase_analysis.py (same folder).
"""

import json
import sys
from datetime import datetime, timedelta

try:
    import requests
except ImportError:
    print("ERROR: 'requests' not installed. Run:  pip install requests")
    sys.exit(1)

from fetch_firebase_analysis import (
    PROJECT_ID, API_KEY, BASE_URL,
    doc_to_dict, analyse_trip, aggregate_analysis,
    fetch_samples_subcollection,
)


def fetch_all_trips():
    trips = []
    token = None
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


def local_date(ms):
    """Convert epoch-ms to a local date string (uses machine timezone)."""
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%Y-%m-%d")
    except Exception:
        return None


def main():
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    print(f"Fetching trips from Firestore … (yesterday = {yesterday}, local time)")
    trips = fetch_all_trips()
    print(f"Fetched {len(trips)} total trip(s).")

    day = [t for t in trips if local_date(t.get("startTimeMs")) == yesterday]
    print(f"Trips recorded yesterday: {len(day)}")

    # The samples live in the trips/{id}/samples subcollection, not on the trip
    # doc, so pull them in before analysing (otherwise every trip reads as 0).
    for t in day:
        if not t.get("samples"):
            t["samples"] = fetch_samples_subcollection(t.get("_doc_name", ""))
        print(f"  {t.get('_doc_name','').split('/')[-1]}: "
              f"{len(t.get('samples') or [])} samples "
              f"({'finalized' if t.get('uploadComplete') else 'NOT finalized'})")

    if not day:
        dated = [(local_date(t.get("startTimeMs")), t) for t in trips if t.get("startTimeMs")]
        dated.sort(key=lambda x: int(x[1]["startTimeMs"]))
        print("\nNo drive found for yesterday. Most recent trips:")
        for d, t in dated[-8:]:
            print(f"  {d}  {t.get('scenario','?')} | {t.get('vehicle','?')} | "
                  f"{len(t.get('samples') or [])} samples")
        return

    raw_path = f"yesterdays_drive_{yesterday}.json"
    with open(raw_path, "w") as f:
        json.dump(day, f, indent=2)

    stats = []
    for t in day:
        s = analyse_trip(t)
        s["_doc"] = t.get("_doc_name", "").split("/")[-1]
        stats.append(s)
    agg = aggregate_analysis(stats)

    lines = [f"YESTERDAY'S DRIVE SUMMARY — {yesterday}", "=" * 50, ""]
    lines.append(f"Drives         : {agg.get('total_trips', 0)}")
    lines.append(f"Total samples  : {agg.get('total_samples', 0)}")
    lines.append(f"Mean speed     : {agg.get('mean_speed_kmh', 0)} km/h")
    lines.append(f"Mean GPS acc   : {agg.get('mean_gps_accuracy_m', 0)} m")
    lines.append("")
    for i, (t, raw) in enumerate(zip(stats, day), 1):
        doc = t.get('_doc', '?')
        status = 'finalized' if raw.get('uploadComplete') else 'NOT finalized'
        lines.append(f"Drive {i}  [{doc} — {status}]  "
                     f"({t.get('scenario','?')} | {t.get('vehicle','?')} | {t.get('mount_type','?')})")
        lines.append(f"  Samples : {t['sample_count']}  Duration: {t.get('duration_s',0):.0f}s")
        lines.append(f"  Speed   : mean {t.get('speed_mean_kmh',0)} km/h  max {t.get('speed_max_kmh',0)} km/h")
        lines.append(f"  Z-score : mean {t.get('z_mean',0)}  p90 {t.get('z_p90',0)}  p99 {t.get('z_p99',0)}  max {t.get('z_max',0)}")
        lines.append(f"  Colors  : green {t.get('pct_green',0)}%  yellow {t.get('pct_yellow',0)}%  "
                     f"orange {t.get('pct_orange',0)}%  red {t.get('pct_red',0)}%")
        lines.append(f"  Events  : braking {t.get('braking_events',0)}  bumps {t.get('bump_events',0)}  "
                     f"low-spd-high-Z {t.get('low_speed_high_z_count',0)}")
        lines.append("")
    report = "\n".join(lines)

    summary_path = "yesterdays_drive_summary.txt"
    with open(summary_path, "w") as f:
        f.write(report)

    print("\n" + report)
    print(f"Saved: {raw_path}  |  {summary_path}")


if __name__ == "__main__":
    main()
