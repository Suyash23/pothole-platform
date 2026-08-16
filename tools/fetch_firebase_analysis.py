#!/usr/bin/env python3
"""
Road Quality Mapper — Firebase Data Fetch & Analysis
=====================================================
Run this script locally (it needs outbound internet access to Firestore).

Usage:
    pip install requests
    python3 fetch_firebase_analysis.py

Output:
    firebase_analysis_summary.json  — key statistics for each trip
    firebase_analysis_report.txt    — human-readable narrative report

The script hits the Firestore REST API using the web API key above and an
anonymous ID token. The rules require a signed-in caller (they were opened to
the whole internet until 2026-08-04); no service-account key is needed.
"""

import json
import math
import sys
from collections import Counter, defaultdict

try:
    import requests
except ImportError:
    print("ERROR: 'requests' not installed. Run:  pip install requests")
    sys.exit(1)

# ── Firebase config ────────────────────────────────────────────────────────────
PROJECT_ID = "pothole-finder-e323f"
API_KEY    = "AIzaSyBvM3i-F0vQKDhjWv8_B80kE2HMe8glhVs"
BASE_URL   = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents"

# ── Authentication ─────────────────────────────────────────────────────────────
#
# These scripts used to read Firestore with nothing but the API key above,
# because the rules were `allow read, write: if true` — the whole database was
# open to the internet. That was fixed on 2026-08-04 (see
# firebase/firestore.rules); reads now require an authenticated caller, so the
# scripts sign in anonymously exactly as the app and dashboard do, and send the
# resulting ID token as a bearer credential.
#
# The token is cached OUTSIDE the repo (~/.pothole_platform_auth.json) and
# reused until it expires, so a tuning session that runs these scripts dozens
# of times does not mint dozens of anonymous accounts. The cache holds a
# refresh token — it is a credential; keep it local, and note the path is
# deliberately not inside the working tree.

import os
import time

_AUTH_CACHE = os.path.expanduser("~/.pothole_platform_auth.json")
_IDENTITY = "https://identitytoolkit.googleapis.com/v1"


def _load_cached_token():
    try:
        with open(_AUTH_CACHE) as f:
            c = json.load(f)
        if c.get("expires_at", 0) > time.time() + 60:
            return c.get("id_token")
        if c.get("refresh_token"):
            r = requests.post(
                f"https://securetoken.googleapis.com/v1/token?key={API_KEY}",
                data={"grant_type": "refresh_token",
                      "refresh_token": c["refresh_token"]},
                timeout=30)
            if r.status_code == 200:
                d = r.json()
                return _save_token(d["id_token"], d["refresh_token"],
                                   int(d.get("expires_in", 3600)))
    except Exception:
        pass
    return None


def _save_token(id_token, refresh_token, expires_in):
    try:
        with open(_AUTH_CACHE, "w") as f:
            json.dump({"id_token": id_token, "refresh_token": refresh_token,
                       "expires_at": time.time() + expires_in}, f)
        os.chmod(_AUTH_CACHE, 0o600)
    except Exception:
        pass
    return id_token


def id_token():
    """Anonymous ID token for Firestore REST calls, cached across runs.

    Returns None (never exits) when sign-in fails, so callers can fall back
    to an unauthenticated request. That fallback matters during the rollout
    window: the rules are deployed as `if true` until the Anonymous provider
    is switched on in the console AND `firebase deploy --only firestore:rules`
    runs (see the ORDER MATTERS section of the README) — until then, every
    script importing this module would otherwise hard-exit at IMPORT TIME,
    which previously broke fetch_lc_diags.py, fetch_impulse_diags.py,
    fetch_todays_drive.py and reconcile_firestore.py too, not just this file.
    """
    cached = _load_cached_token()
    if cached:
        return cached
    try:
        r = requests.post(f"{_IDENTITY}/accounts:signUp?key={API_KEY}",
                          json={"returnSecureToken": True}, timeout=30)
    except requests.exceptions.RequestException as e:
        print(f"WARNING: anonymous sign-in request failed ({e}); "
              "falling back to unauthenticated requests.")
        return None
    if r.status_code != 200:
        print(f"WARNING: anonymous sign-in failed ({r.status_code}): {r.text[:200]}")
        print("Is Anonymous sign-in enabled? Firebase console → Authentication "
              "→ Sign-in method → Anonymous. Falling back to unauthenticated "
              "requests — this only works while firestore.rules still allows it.")
        return None
    d = r.json()
    return _save_token(d["idToken"], d["refreshToken"],
                       int(d.get("expiresIn", 3600)))


# Every script issues its Firestore calls through this session, so the bearer
# token is attached in exactly one place. Import it instead of using `requests`
# directly:  from fetch_firebase_analysis import SESSION
SESSION = requests.Session()
_token = id_token()
if _token:
    SESSION.headers.update({"Authorization": f"Bearer {_token}"})

# ── Helpers ────────────────────────────────────────────────────────────────────

def firestore_value(v):
    """Unwrap a Firestore typed-value dict to a plain Python value."""
    if not isinstance(v, dict):
        return v
    if "stringValue"    in v: return v["stringValue"]
    if "integerValue"   in v: return int(v["integerValue"])
    if "doubleValue"    in v: return float(v["doubleValue"])
    if "booleanValue"   in v: return bool(v["booleanValue"])
    if "nullValue"      in v: return None
    if "timestampValue" in v: return v["timestampValue"]
    if "arrayValue"     in v:
        return [firestore_value(i) for i in v["arrayValue"].get("values", [])]
    if "mapValue"       in v:
        return {k: firestore_value(fv) for k, fv in v["mapValue"].get("fields", {}).items()}
    return v

def doc_to_dict(doc):
    """Convert a full Firestore REST document to a plain Python dict."""
    fields = doc.get("fields", {})
    return {k: firestore_value(v) for k, v in fields.items()}

def fetch_samples_subcollection(doc_name):
    """Pull the trips/{id}/samples subcollection batches into a flat sample list.

    The current app schema stores samples in this subcollection (as batch docs
    each holding a `samples` array), NOT as an inline `samples` array on the
    trip document. analyse_trip() reads `trip["samples"]`, so callers must
    populate it via this helper or every trip looks empty.
    """
    trip_id = doc_name.split("/")[-1]
    if not trip_id:
        return []
    samples = []
    page_token = None
    while True:
        url = f"{BASE_URL}/trips/{trip_id}/samples?key={API_KEY}&pageSize=50"
        if page_token:
            url += f"&pageToken={page_token}"
        try:
            r = SESSION.get(url, timeout=30)
        except requests.exceptions.RequestException as e:
            print(f"    subcollection fetch error for {trip_id}: {e}")
            break
        if r.status_code != 200:
            break
        data = r.json()
        for doc in data.get("documents", []):
            batch = doc_to_dict(doc).get("samples", [])
            if isinstance(batch, list):
                samples.extend(batch)
        page_token = data.get("nextPageToken")
        if not page_token:
            break
    return samples


def fetch_all_trips():
    """Paginate through the trips collection and return a list of plain dicts."""
    trips = []
    page_token = None
    page = 0
    while True:
        page += 1
        url = f"{BASE_URL}/trips?key={API_KEY}&pageSize=20"
        if page_token:
            url += f"&pageToken={page_token}"
        print(f"  Fetching page {page} …", end="", flush=True)
        try:
            r = SESSION.get(url, timeout=30)
        except requests.exceptions.ConnectionError as e:
            print(f"\nERROR: Could not connect to Firestore.\n  {e}")
            print("  Make sure you are NOT behind a restrictive proxy "
                  "and that this script is run on your local machine.")
            sys.exit(1)
        if r.status_code == 403:
            print(f"\nERROR 403 Forbidden — check your Firestore security rules allow reads.")
            sys.exit(1)
        if r.status_code != 200:
            print(f"\nERROR {r.status_code}: {r.text[:200]}")
            sys.exit(1)
        data = r.json()
        docs = data.get("documents", [])
        print(f" got {len(docs)} docs")
        for doc in docs:
            d = doc_to_dict(doc)
            d["_doc_name"] = doc.get("name", "")
            trips.append(d)
        page_token = data.get("nextPageToken")
        if not page_token:
            break
    return trips

# ── Statistical helpers ────────────────────────────────────────────────────────

def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    idx = (len(sorted_vals) - 1) * p / 100
    lo  = int(idx)
    hi  = min(lo + 1, len(sorted_vals) - 1)
    frac = idx - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac

def mean(vals):
    return sum(vals) / len(vals) if vals else 0.0

def stdev(vals):
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))

def histogram(vals, bins=10, lo=None, hi=None):
    if not vals:
        return []
    lo = lo if lo is not None else min(vals)
    hi = hi if hi is not None else max(vals)
    if lo == hi:
        return [(lo, hi, len(vals))]
    width = (hi - lo) / bins
    counts = [0] * bins
    for v in vals:
        idx = min(int((v - lo) / width), bins - 1)
        counts[idx] += 1
    return [(lo + i * width, lo + (i + 1) * width, counts[i]) for i in range(bins)]

# ── Per-trip analysis ──────────────────────────────────────────────────────────

def analyse_trip(trip):
    """Return a stats dict for one trip document."""
    samples = trip.get("samples", [])
    if not isinstance(samples, list):
        samples = []

    n = len(samples)
    if n == 0:
        return {"sample_count": 0}

    # Duration from the trip doc's start/end when finalized; otherwise fall back
    # to the sample timestamp range (unfinalized trips have no endTimeMs, which
    # would otherwise yield a nonsensical negative duration).
    start_ms = trip.get("startTimeMs") or 0
    end_ms   = trip.get("endTimeMs") or 0
    if end_ms and start_ms and end_ms >= start_ms:
        duration_s = (end_ms - start_ms) / 1000
    else:
        sample_ts = [s.get("ts") for s in samples if isinstance(s, dict) and s.get("ts")]
        duration_s = (max(sample_ts) - min(sample_ts)) / 1000 if len(sample_ts) >= 2 else 0.0

    z_scores       = [s.get("z_score", 0.0) for s in samples if isinstance(s, dict)]
    speeds_mps     = [s.get("speed", 0.0)   for s in samples if isinstance(s, dict)]
    speeds_kmh     = [v * 3.6 for v in speeds_mps]
    colors         = [s.get("color", "green") for s in samples if isinstance(s, dict)]
    accuracies     = [s.get("accuracy", 0.0) for s in samples if isinstance(s, dict) if s.get("accuracy")]
    is_braking     = [s for s in samples if isinstance(s, dict) and s.get("isBraking")]
    is_bump        = [s for s in samples if isinstance(s, dict) and s.get("isBump")]
    altitudes      = [s.get("altitude", 0.0) for s in samples if isinstance(s, dict)]

    # Gravity vectors — detect phone placement
    grav_angles = []
    for s in samples:
        if not isinstance(s, dict):
            continue
        gx = s.get("gravX", 0.0)
        gy = s.get("gravY", 0.0)
        gz = s.get("gravZ", 0.0)
        mag = math.sqrt(gx**2 + gy**2 + gz**2)
        if mag > 0.5:
            # Angle of gravity from vertical (Z axis in phone frame)
            tilt_deg = math.degrees(math.acos(min(1.0, abs(gz) / mag)))
            grav_angles.append(tilt_deg)

    # Mount stability: std-dev of gravity tilt angles as a wobble proxy
    mount_wobble_stddev = stdev(grav_angles) if grav_angles else 0.0

    sorted_z = sorted(z_scores)
    sorted_spd = sorted(speeds_kmh)

    color_counts = Counter(colors)
    total = max(n, 1)

    # Suspicious: pothole-level Z-score at low speed (possible false positive)
    low_speed_pothole = [
        s for s in samples
        if isinstance(s, dict)
        and s.get("z_score", 0.0) >= 4.0
        and s.get("speed", 0.0) * 3.6 < 10.0
    ]

    return {
        "sample_count":           n,
        "duration_s":             duration_s,
        "fidelity":               trip.get("fidelity", "?"),
        "vehicle":                trip.get("vehicle", "?"),
        "mount_type":             trip.get("mountType", "?"),
        "scenario":               trip.get("scenario", "?"),

        # Z-score distribution
        "z_mean":                 round(mean(z_scores), 3),
        "z_stdev":                round(stdev(z_scores), 3),
        "z_p50":                  round(percentile(sorted_z, 50), 3) if sorted_z else 0,
        "z_p90":                  round(percentile(sorted_z, 90), 3) if sorted_z else 0,
        "z_p99":                  round(percentile(sorted_z, 99), 3) if sorted_z else 0,
        "z_max":                  round(max(z_scores), 3) if z_scores else 0,

        # Color distribution (road quality breakdown)
        "pct_green":              round(color_counts.get("green",  0) / total * 100, 1),
        "pct_yellow":             round(color_counts.get("yellow", 0) / total * 100, 1),
        "pct_orange":             round(color_counts.get("orange", 0) / total * 100, 1),
        "pct_red":                round(color_counts.get("red",    0) / total * 100, 1),

        # Speed
        "speed_mean_kmh":         round(mean(speeds_kmh), 1),
        "speed_p10_kmh":          round(percentile(sorted_spd, 10), 1) if sorted_spd else 0,
        "speed_max_kmh":          round(max(speeds_kmh), 1) if speeds_kmh else 0,

        # GPS accuracy
        "gps_accuracy_mean_m":    round(mean(accuracies), 2) if accuracies else 0,
        "gps_accuracy_p90_m":     round(percentile(sorted(accuracies), 90), 2) if accuracies else 0,

        # Events
        "braking_events":         len(is_braking),
        "bump_events":            len(is_bump),

        # False positive proxy: high-Z events at low speed
        "low_speed_high_z_count": len(low_speed_pothole),

        # Mount stability
        "mount_wobble_stddev_deg": round(mount_wobble_stddev, 3),

        # Altitude range (useful to flag bridge/tunnel segments)
        "altitude_min_m":         round(min(altitudes), 1) if altitudes else 0,
        "altitude_max_m":         round(max(altitudes), 1) if altitudes else 0,
        "altitude_range_m":       round(max(altitudes) - min(altitudes), 1) if altitudes else 0,
    }

# ── Cross-trip aggregate analysis ─────────────────────────────────────────────

def aggregate_analysis(trip_stats):
    if not trip_stats:
        return {}

    def collect(key):
        return [t[key] for t in trip_stats if isinstance(t.get(key), (int, float))]

    all_z_mean   = collect("z_mean")
    all_z_p99    = collect("z_p99")
    all_wobble   = collect("mount_wobble_stddev_deg")
    all_fp       = collect("low_speed_high_z_count")
    all_acc      = collect("gps_accuracy_mean_m")
    all_speed    = collect("speed_mean_kmh")

    mount_noise = defaultdict(list)
    for t in trip_stats:
        mt = t.get("mount_type", "unknown") or "unknown"
        mount_noise[mt].append(t.get("z_mean", 0.0))

    mount_baselines = {mt: round(mean(vals), 3) for mt, vals in mount_noise.items()}

    vehicle_noise = defaultdict(list)
    for t in trip_stats:
        v = t.get("vehicle", "unknown") or "unknown"
        vehicle_noise[v].append(t.get("z_mean", 0.0))
    vehicle_baselines = {v: round(mean(vals), 3) for v, vals in vehicle_noise.items()}

    return {
        "total_trips":          len(trip_stats),
        "total_samples":        sum(collect("sample_count")),
        "mean_z_across_trips":  round(mean(all_z_mean), 3),
        "mean_z_p99":           round(mean(all_z_p99), 3),
        "mean_mount_wobble":    round(mean(all_wobble), 3),
        "trips_with_fp_risk":   sum(1 for fp in all_fp if fp > 0),
        "mean_gps_accuracy_m":  round(mean(all_acc), 2),
        "mean_speed_kmh":       round(mean(all_speed), 1),
        "mount_type_baselines": mount_baselines,
        "vehicle_baselines":    vehicle_baselines,
    }

# ── Report generation ─────────────────────────────────────────────────────────

def write_report(trip_stats, agg, output_path):
    lines = []
    a = lines.append

    a("=" * 70)
    a("  ROAD QUALITY MAPPER — FIREBASE ANALYSIS REPORT")
    a("=" * 70)
    a("")
    a(f"Total trips analysed : {agg.get('total_trips', 0)}")
    a(f"Total GPS samples    : {agg.get('total_samples', 0)}")
    a(f"Mean GPS accuracy    : {agg.get('mean_gps_accuracy_m', 0)} m")
    a(f"Mean driving speed   : {agg.get('mean_speed_kmh', 0)} km/h")
    a("")

    a("── Z-SCORE BASELINE ──────────────────────────────────────────────────")
    a(f"  Mean Z across all trips : {agg.get('mean_z_across_trips', 0)}")
    a(f"  Mean P99 Z              : {agg.get('mean_z_p99', 0)}")
    a("  Interpretation: A mean Z ~0 and P99 ~2-3 is healthy. "
      "If P99 > 5 consistently,\n  your pothole threshold (4.0) may be too loose.")
    a("")

    a("── MOUNT TYPE NOISE BASELINES ────────────────────────────────────────")
    for mt, baseline in agg.get("mount_type_baselines", {}).items():
        a(f"  {mt:25s}  baseline Z-mean = {baseline}")
    a("  Mounts with high baseline Z-mean produce more false positives.")
    a("")

    a("── VEHICLE BASELINES ─────────────────────────────────────────────────")
    for v, baseline in agg.get("vehicle_baselines", {}).items():
        a(f"  {v:30s}  baseline Z-mean = {baseline}")
    a("")

    a("── MOUNT WOBBLE DETECTION ────────────────────────────────────────────")
    a(f"  Mean mount wobble (stdev of gravity tilt) : {agg.get('mean_mount_wobble', 0):.2f}°")
    a("  Trips with wobble stdev > 5° are candidates for 'wobbly mount' flag.")
    wobble_trips = [t for t in trip_stats if t.get("mount_wobble_stddev_deg", 0) > 5.0]
    a(f"  Trips flagged wobbly (>5° stdev)          : {len(wobble_trips)}")
    a("")

    a("── FALSE POSITIVE RISK ───────────────────────────────────────────────")
    a(f"  Trips with high-Z events at low speed : {agg.get('trips_with_fp_risk', 0)}")
    a("  These are Z≥4.0 events recorded below 10 km/h — likely phone handling,")
    a("  stop signs, or speed gates not firing fast enough.")
    a("")

    a("── PER-TRIP SUMMARY ──────────────────────────────────────────────────")
    for i, t in enumerate(trip_stats, 1):
        a(f"\n  Trip {i:02d}  ({t.get('scenario','?')} | {t.get('vehicle','?')} | {t.get('mount_type','?')})")
        a(f"    Samples: {t['sample_count']}  |  Duration: {t.get('duration_s',0):.0f}s  |  Fidelity: {t.get('fidelity','?')}")
        a(f"    Speed  : mean {t.get('speed_mean_kmh',0)} km/h  |  max {t.get('speed_max_kmh',0)} km/h")
        a(f"    Z-score: mean {t.get('z_mean',0)}  p90 {t.get('z_p90',0)}  p99 {t.get('z_p99',0)}  max {t.get('z_max',0)}")
        a(f"    Colors : 🟢 {t.get('pct_green',0)}%  🟡 {t.get('pct_yellow',0)}%  🟠 {t.get('pct_orange',0)}%  🔴 {t.get('pct_red',0)}%")
        a(f"    GPS acc: mean {t.get('gps_accuracy_mean_m',0)} m  p90 {t.get('gps_accuracy_p90_m',0)} m")
        a(f"    Events : braking={t.get('braking_events',0)}  bumps={t.get('bump_events',0)}  low-spd-high-Z={t.get('low_speed_high_z_count',0)}")
        a(f"    Mount wobble stdev: {t.get('mount_wobble_stddev_deg',0):.2f}°  |  Altitude range: {t.get('altitude_range_m',0)} m")

    a("")
    a("=" * 70)
    a("  END OF REPORT")
    a("=" * 70)

    text = "\n".join(lines)
    with open(output_path, "w") as f:
        f.write(text)
    return text

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    print("\n🔥 Road Quality Mapper — Firebase Analysis")
    print("─" * 50)
    print("Fetching trips from Firestore …")
    trips = fetch_all_trips()
    print(f"\nFetched {len(trips)} trip document(s).\n")

    if not trips:
        print("No trips found. Make sure Firestore has data and rules allow reads.")
        return

    print("Analysing trip data …")
    trip_stats = []
    for i, trip in enumerate(trips):
        print(f"  Trip {i+1}/{len(trips)}: {trip.get('scenario','?')} | {trip.get('vehicle','?')}")
        stats = analyse_trip(trip)
        stats["_doc"] = trip.get("_doc_name", "").split("/")[-1]
        trip_stats.append(stats)

    agg = aggregate_analysis(trip_stats)

    summary_path = "firebase_analysis_summary.json"
    report_path  = "firebase_analysis_report.txt"

    with open(summary_path, "w") as f:
        json.dump({"aggregate": agg, "trips": trip_stats}, f, indent=2)

    report_text = write_report(trip_stats, agg, report_path)
    print("\n" + report_text)
    print(f"\n✅ Saved: {summary_path}  |  {report_path}")

if __name__ == "__main__":
    main()
