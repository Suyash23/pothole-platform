#!/usr/bin/env python3
"""
Speed-Threshold Calibration Analysis
=====================================
Pulls all GPS samples from Firestore and answers the question:
"What should the pothole Z-score threshold be at each speed?"

Usage:
    pip install requests
    python3 analyze_speed_thresholds.py

Output printed to terminal + saved to speed_threshold_report.txt
"""

import json
import math
import sys
from collections import defaultdict

try:
    import requests
except ImportError:
    sys.exit("Run:  pip install requests")

# Firestore rules require a signed-in caller (they were world-open until
# 2026-08-04). SESSION carries the anonymous ID token.
from fetch_firebase_analysis import SESSION

PROJECT_ID = "pothole-finder-e323f"
API_KEY    = "AIzaSyBvM3i-F0vQKDhjWv8_B80kE2HMe8glhVs"
BASE_URL   = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents"

# Speed buckets (km/h)
BUCKETS = [
    (10,  20,  "10–20  km/h  (slow city)"),
    (20,  40,  "20–40  km/h  (city)"),
    (40,  60,  "40–60  km/h  (arterial)"),
    (60,  80,  "60–80  km/h  (fast arterial)"),
    (80,  100, "80–100 km/h  (freeway entry)"),
    (100, 999, "100+   km/h  (freeway)"),
]

# ── helpers ───────────────────────────────────────────────────────────────────

def fv(v):
    if not isinstance(v, dict): return v
    if "stringValue"  in v: return v["stringValue"]
    if "integerValue" in v: return int(v["integerValue"])
    if "doubleValue"  in v: return float(v["doubleValue"])
    if "booleanValue" in v: return bool(v["booleanValue"])
    if "nullValue"    in v: return None
    if "arrayValue"   in v: return [fv(i) for i in v["arrayValue"].get("values", [])]
    if "mapValue"     in v: return {k: fv(fv2) for k, fv2 in v["mapValue"].get("fields", {}).items()}
    return v

def doc_to_dict(doc):
    return {k: fv(v) for k, v in doc.get("fields", {}).items()}

def pct(sorted_vals, p):
    if not sorted_vals: return None
    idx  = (len(sorted_vals) - 1) * p / 100
    lo   = int(idx); hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] * (1 - (idx - lo)) + sorted_vals[hi] * (idx - lo)

def mean(vals): return sum(vals) / len(vals) if vals else 0.0

def stdev(vals):
    if len(vals) < 2: return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))

# ── fetch ─────────────────────────────────────────────────────────────────────

def fetch_trips():
    trips, page_token, page = [], None, 0
    while True:
        page += 1
        url = f"{BASE_URL}/trips?key={API_KEY}&pageSize=20"
        if page_token: url += f"&pageToken={page_token}"
        print(f"  Fetching page {page}…", end="", flush=True)
        try:
            r = SESSION.get(url, timeout=30)
        except Exception as e:
            sys.exit(f"\nConnection error: {e}\nRun this script on your local machine.")
        if r.status_code != 200:
            sys.exit(f"\nHTTP {r.status_code}: {r.text[:300]}")
        data = r.json()
        docs = data.get("documents", [])
        print(f" {len(docs)} trips")
        trips.extend(doc_to_dict(d) for d in docs)
        page_token = data.get("nextPageToken")
        if not page_token: break
    return trips

def fetch_samples_subcollection(trip_doc_name):
    """Fetch sample batches from trips/{id}/samples subcollection."""
    samples = []
    trip_id = trip_doc_name.split("/")[-1]
    page_token = None
    while True:
        url = f"{BASE_URL}/trips/{trip_id}/samples?key={API_KEY}&pageSize=20"
        if page_token: url += f"&pageToken={page_token}"
        try:
            r = SESSION.get(url, timeout=30)
        except Exception as e:
            print(f"\n    Subcollection fetch error: {e}")
            break
        if r.status_code != 200:
            break
        data = r.json()
        for doc in data.get("documents", []):
            d = doc_to_dict(doc)
            batch = d.get("samples", [])
            if isinstance(batch, list):
                samples.extend(batch)
        page_token = data.get("nextPageToken")
        if not page_token: break
    return samples

def collect_all_samples(trips):
    """Return flat list of all GPS samples across all trips, with trip metadata attached."""
    all_samples = []
    for i, trip in enumerate(trips):
        doc_name = trip.get("_doc_name", "")
        vehicle   = trip.get("vehicle", "unknown")
        mount     = trip.get("mountType", "unknown")
        scenario  = trip.get("scenario", "unknown")

        # Try subcollection first (new format), fall back to inline array (old format)
        raw = fetch_samples_subcollection(doc_name) if doc_name else []
        if not raw:
            raw = trip.get("samples", [])
        if not isinstance(raw, list):
            raw = []

        print(f"    Trip {i+1}: {scenario} | {vehicle} | {mount} → {len(raw)} samples")
        for s in raw:
            if not isinstance(s, dict): continue
            s["_vehicle"]  = vehicle
            s["_mount"]    = mount
            s["_scenario"] = scenario
            all_samples.append(s)
    return all_samples

# ── analysis ─────────────────────────────────────────────────────────────────

def bucket_for(speed_kmh):
    for lo, hi, label in BUCKETS:
        if lo <= speed_kmh < hi:
            return label
    return None

def analyse(all_samples):
    # Group Z-scores by speed bucket
    bucket_z: dict[str, list[float]] = defaultdict(list)
    # Also group known-event Z-scores (isBraking, isBump, userLabel != null)
    bucket_event_z: dict[str, list[float]] = defaultdict(list)

    total = len(all_samples)
    skipped = 0

    for s in all_samples:
        speed_mps = s.get("speed", 0.0) or 0.0
        speed_kmh = speed_mps * 3.6
        z = s.get("z_score", None) or s.get("zScore", None)
        if z is None: z = s.get("z_Score", 0.0)
        try:
            z = float(z)
            speed_kmh = float(speed_kmh)
        except (TypeError, ValueError):
            skipped += 1
            continue

        if speed_kmh < 10.0: continue  # below speed gate

        b = bucket_for(speed_kmh)
        if b is None: continue

        bucket_z[b].append(z)

        # Mark as "known event" if any anomaly flag is set
        is_event = (
            s.get("isBraking") or s.get("is_braking") or
            s.get("isBump")    or s.get("is_bump") or
            s.get("isLaneChange") or s.get("is_lane_change") or
            (s.get("userLabel") or s.get("user_label"))
        )
        if is_event:
            bucket_event_z[b].append(z)

    print(f"\n  Parsed {total} samples ({skipped} skipped — missing speed or z_score)")
    return bucket_z, bucket_event_z

def recommend_threshold(sorted_z, false_positive_target_pct=2.0):
    """
    Find the Z-score threshold such that only `false_positive_target_pct`%
    of baseline (non-event) samples would exceed it.
    That's the P(100 - target) percentile of the distribution.
    """
    return pct(sorted_z, 100 - false_positive_target_pct)

def report(bucket_z, bucket_event_z):
    lines = []
    a = lines.append

    a("=" * 72)
    a("  POTHOLE THRESHOLD CALIBRATION  —  Z-score by speed bucket")
    a("=" * 72)
    a("")
    a("Current fixed threshold: Z ≥ 4.0 for all speeds")
    a("")
    a(f"{'Speed bucket':<26} {'n':>6}  {'mean':>6}  {'p90':>6}  {'p95':>6}  {'p99':>6}  {'max':>6}  {'rec≥2%FP':>9}")
    a("-" * 72)

    recommended = {}
    for lo, hi, label in BUCKETS:
        zs = sorted(bucket_z.get(label, []))
        if not zs:
            a(f"  {label:<24}   (no data)")
            continue
        n   = len(zs)
        m   = mean(zs)
        p90 = pct(zs, 90)
        p95 = pct(zs, 95)
        p99 = pct(zs, 99)
        mx  = max(zs)
        rec = recommend_threshold(zs, false_positive_target_pct=2.0)
        recommended[label] = rec

        a(f"  {label:<24} {n:>6}  {m:>6.2f}  {p90:>6.2f}  {p95:>6.2f}  {p99:>6.2f}  {mx:>6.2f}  {rec:>9.2f}")

    a("")
    a("  'rec≥2%FP' = threshold where only 2% of samples in that speed bucket")
    a("  would exceed it under normal road conditions (P98 of the distribution).")
    a("")

    a("── KNOWN-EVENT Z-SCORES (isBraking / isBump / userLabel) ────────────")
    a(f"{'Speed bucket':<26} {'n':>6}  {'mean':>6}  {'p50':>6}  {'p10':>6}  {'min':>6}")
    a("-" * 72)
    for lo, hi, label in BUCKETS:
        ez = sorted(bucket_event_z.get(label, []))
        if not ez:
            a(f"  {label:<24}   (no tagged events)")
            continue
        a(f"  {label:<24} {len(ez):>6}  {mean(ez):>6.2f}  {pct(ez,50):>6.2f}  {pct(ez,10):>6.2f}  {min(ez):>6.2f}")

    a("")
    a("  P10 of event Z-scores = the minimum threshold that catches 90% of")
    a("  known events in that bucket. Should be BELOW your detection threshold.")
    a("")

    a("── THRESHOLD RECOMMENDATION ──────────────────────────────────────────")
    a("")
    a("  Based on your data, suggested speed-adaptive thresholds:")
    a("")
    current = 4.0
    for lo, hi, label in BUCKETS:
        rec = recommended.get(label)
        if rec is None:
            a(f"  {label:<24}  → no data yet, keep {current:.1f}")
            continue
        # Round to nearest 0.25 for clean config values
        rounded = round(rec * 4) / 4
        direction = "↑ raise" if rounded > current else ("↓ lower" if rounded < current else "= keep ")
        a(f"  {label:<24}  → {rounded:.2f}  ({direction} from {current:.1f})")

    a("")
    a("  These are P98 thresholds — calibrated so 2% of normal driving at that")
    a("  speed would trigger a false positive. Adjust the target % to trade")
    a("  sensitivity vs specificity.")
    a("")
    a("=" * 72)

    text = "\n".join(lines)
    print("\n" + text)
    with open("speed_threshold_report.txt", "w") as f:
        f.write(text)
    print("\n✅  Saved to speed_threshold_report.txt")
    return text

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    print("\n🚗  Speed-Threshold Calibration Analysis")
    print("─" * 50)
    print("Fetching trips…")
    trips = fetch_trips()
    # Attach doc name for subcollection lookup
    # (Re-fetch raw to get doc names — the earlier fetch strips them)
    # Actually re-fetch with names preserved:
    trips_with_names = []
    page_token = None
    while True:
        url = f"{BASE_URL}/trips?key={API_KEY}&pageSize=20"
        if page_token: url += f"&pageToken={page_token}"
        r = SESSION.get(url, timeout=30)
        data = r.json()
        for doc in data.get("documents", []):
            d = doc_to_dict(doc)
            d["_doc_name"] = doc.get("name", "")
            trips_with_names.append(d)
        page_token = data.get("nextPageToken")
        if not page_token: break

    print(f"\nCollecting samples from {len(trips_with_names)} trip(s)…")
    all_samples = collect_all_samples(trips_with_names)
    print(f"\nTotal samples collected: {len(all_samples)}")

    if not all_samples:
        print("\nNo samples found. Check Firestore security rules allow reads.")
        return

    print("\nAnalysing Z-score distribution by speed bucket…")
    bucket_z, bucket_event_z = analyse(all_samples)
    report(bucket_z, bucket_event_z)

if __name__ == "__main__":
    main()
