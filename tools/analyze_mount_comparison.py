#!/usr/bin/env python3
"""
Mount Type Comparison Analysis
================================
Pulls all trips + GPS samples from Firestore and compares how different
phone mount types affect sensor noise, false-positive rates, and
road-anomaly detection quality.

Usage:
    pip install requests
    python3 analyze_mount_comparison.py

Output: printed to terminal + saved to mount_comparison_report.txt
"""

import json
import math
import sys
from collections import defaultdict

try:
    import requests
except ImportError:
    sys.exit("Run:  pip install requests")

PROJECT_ID = "pothole-finder-e323f"
API_KEY    = "AIzaSyBvM3i-F0vQKDhjWv8_B80kE2HMe8glhVs"
BASE_URL   = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents"

# ── helpers ───────────────────────────────────────────────────────────────────

def fv(v):
    if not isinstance(v, dict): return v
    if "stringValue"  in v: return v["stringValue"]
    if "integerValue" in v: return int(v["integerValue"])
    if "doubleValue"  in v: return float(v["doubleValue"])
    if "booleanValue" in v: return bool(v["booleanValue"])
    if "nullValue"    in v: return None
    if "arrayValue"   in v: return [fv(i) for i in v["arrayValue"].get("values", [])]
    if "mapValue"     in v: return {k: fv(w) for k, w in v["mapValue"].get("fields", {}).items()}
    return v

def doc_to_dict(doc):
    return {k: fv(v) for k, v in doc.get("fields", {}).items()}

def pct(sorted_vals, p):
    if not sorted_vals: return None
    idx = (len(sorted_vals) - 1) * p / 100
    lo  = int(idx); hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] * (1 - (idx - lo)) + sorted_vals[hi] * (idx - lo)

def mean(vals):  return sum(vals) / len(vals) if vals else 0.0
def stdev(vals):
    if len(vals) < 2: return 0.0
    m = mean(vals)
    return math.sqrt(sum((x - m) ** 2 for x in vals) / len(vals))

# ── fetch ─────────────────────────────────────────────────────────────────────

def fetch_all_trips():
    trips, page_token = [], None
    page = 0
    while True:
        page += 1
        url = f"{BASE_URL}/trips?key={API_KEY}&pageSize=20"
        if page_token: url += f"&pageToken={page_token}"
        print(f"  Fetching trip page {page}…", end="", flush=True)
        r = requests.get(url, timeout=30)
        if r.status_code != 200:
            sys.exit(f"\nHTTP {r.status_code}: {r.text[:300]}")
        data = r.json()
        docs = data.get("documents", [])
        print(f" {len(docs)} trips")
        for doc in docs:
            d = doc_to_dict(doc)
            d["_doc_name"] = doc.get("name", "")
            trips.append(d)
        page_token = data.get("nextPageToken")
        if not page_token: break
    return trips

def fetch_samples_for_trip(trip_doc_name):
    """Fetch sample batches from trips/{id}/samples subcollection."""
    samples   = []
    trip_id   = trip_doc_name.split("/")[-1]
    page_token = None
    while True:
        url = f"{BASE_URL}/trips/{trip_id}/samples?key={API_KEY}&pageSize=20"
        if page_token: url += f"&pageToken={page_token}"
        r = requests.get(url, timeout=30)
        if r.status_code != 200: break
        data = r.json()
        for doc in data.get("documents", []):
            d     = doc_to_dict(doc)
            batch = d.get("samples", [])
            if isinstance(batch, list):
                samples.extend(batch)
        page_token = data.get("nextPageToken")
        if not page_token: break
    # Fall back to inline array (older format)
    return samples

# ── analysis ─────────────────────────────────────────────────────────────────

def normalise_mount(raw):
    """Normalise mount-type strings to canonical names."""
    if not raw or str(raw).strip().lower() in ("", "unknown", "none", "null"):
        return "Unknown"
    m = str(raw).strip().lower()
    if any(x in m for x in ("stiff", "rigid", "hard", "bolt", "screw", "fixed")):
        return "Stiff/Rigid"
    if any(x in m for x in ("vent", "clip", "ac", "a/c")):
        return "Vent Clip"
    if any(x in m for x in ("dash", "suction", "cup", "windshield", "windscreen")):
        return "Dash/Suction"
    if any(x in m for x in ("hand", "held", "lap", "pocket", "bag")):
        return "Handheld"
    if any(x in m for x in ("cup", "holder")):
        return "Cup Holder"
    return raw.strip().title()

class MountStats:
    def __init__(self, name):
        self.name        = name
        self.trip_count  = 0
        self.z_scores    = []      # all z-scores while moving (>10 km/h)
        self.anomaly_z   = []      # z-scores when an anomaly flag is set
        self.gyro_spikes = 0       # samples where |gyro| > 2.0 rad/s (handling noise)
        self.total_moving= 0       # samples while moving
        self.fp_triggers = 0       # z >= 2.25 without any anomaly flag (likely false positives)
        self.true_events = 0       # z >= 2.25 WITH an anomaly flag
        self.speed_kmh   = []      # speeds to understand driving context

    def add_sample(self, s):
        speed_mps = float(s.get("speed", 0) or 0)
        speed_kmh = speed_mps * 3.6
        if speed_kmh < 10.0: return  # below speed gate

        z = s.get("z_score") or s.get("zScore") or s.get("z_Score") or 0.0
        try: z = float(z)
        except: return

        gx = float(s.get("gx", 0) or 0)
        gy = float(s.get("gy", 0) or 0)
        gz = float(s.get("gz", 0) or 0)
        gyro_mag = math.sqrt(gx*gx + gy*gy + gz*gz)

        is_flagged = bool(
            s.get("isBraking") or s.get("is_braking") or
            s.get("isBump")    or s.get("is_bump") or
            s.get("isLaneChange") or s.get("is_lane_change") or
            (s.get("userLabel") or s.get("user_label"))
        )

        self.total_moving += 1
        self.z_scores.append(z)
        self.speed_kmh.append(speed_kmh)

        if gyro_mag > 2.0:
            self.gyro_spikes += 1

        if is_flagged:
            self.anomaly_z.append(z)

        if z >= 2.25:
            if is_flagged:
                self.true_events += 1
            else:
                self.fp_triggers += 1

    def noise_floor(self):
        """Median Z-score — represents baseline road noise level."""
        s = sorted(self.z_scores)
        return pct(s, 50) if s else None

    def p95(self):
        s = sorted(self.z_scores)
        return pct(s, 95) if s else None

    def p99(self):
        s = sorted(self.z_scores)
        return pct(s, 99) if s else None

    def fp_rate_pct(self):
        if not self.total_moving: return None
        return 100.0 * self.fp_triggers / self.total_moving

    def gyro_spike_pct(self):
        if not self.total_moving: return None
        return 100.0 * self.gyro_spikes / self.total_moving

    def mean_speed(self):
        return mean(self.speed_kmh)

# ── report ────────────────────────────────────────────────────────────────────

def report(mount_stats: dict[str, MountStats], trip_summary: list):
    lines = []
    a = lines.append

    a("=" * 74)
    a("  PHONE MOUNT COMPARISON  —  Road Quality Mapper")
    a("=" * 74)
    a("")

    # Trip summary
    a("── TRIPS BY MOUNT TYPE ───────────────────────────────────────────────")
    a("")
    for t in trip_summary:
        a(f"  Trip {t['id']:>3} │ {t['mount']:<22} │ {t['scenario'] or '—':<22} │ "
          f"{t['samples']:>5} samples  │ {t['vehicle'] or '—'}")
    a("")

    # Per-mount stats
    a("── SENSOR NOISE FLOOR BY MOUNT ───────────────────────────────────────")
    a("")
    a(f"  {'Mount type':<22}  {'trips':>5}  {'samples':>7}  "
      f"{'noise\nfloor':>6}  {'p95 Z':>6}  {'p99 Z':>6}  "
      f"{'gyro\nspike%':>7}  {'FP\nrate%':>7}  {'mean\nspeed':>7}")
    a(f"  {'':<22}  {'':>5}  {'':>7}  {'(med Z)':>6}  {'':>6}  {'':>6}  "
      f"{'(>2r/s)':>7}  {'(Z≥2.25':>7}  {'km/h':>7}")
    a(f"  {'':<22}  {'':>5}  {'':>7}  {'':>6}  {'':>6}  {'':>6}  "
      f"{'':>7}  {'unflag)':>7}  {'':>7}")
    a("-" * 74)

    # Sort by noise floor ascending (quieter = better)
    sorted_mounts = sorted(
        mount_stats.values(),
        key=lambda m: m.noise_floor() if m.noise_floor() is not None else 999
    )

    for m in sorted_mounts:
        nf  = m.noise_floor()
        p95 = m.p95()
        p99 = m.p99()
        fp  = m.fp_rate_pct()
        gs  = m.gyro_spike_pct()
        spd = m.mean_speed()

        a(f"  {m.name:<22}  {m.trip_count:>5}  {m.total_moving:>7}  "
          f"{nf:>6.3f}  {p95:>6.2f}  {p99:>6.2f}  "
          f"{gs:>6.2f}%  {fp:>6.3f}%  {spd:>6.1f}")

    a("")
    a("  Noise floor  = median Z-score while driving >10 km/h.")
    a("                Lower is better — quieter mount, less baseline vibration.")
    a("  Gyro spike % = % of samples where |gyro| > 2.0 rad/s (mount wobble).")
    a("  FP rate %    = % of samples with Z ≥ 2.25 but NO anomaly flag set")
    a("                (likely false positives from mount resonance).")
    a("")

    # Ranking & interpretation
    a("── RANKING & INTERPRETATION ──────────────────────────────────────────")
    a("")

    for rank, m in enumerate(sorted_mounts, 1):
        nf = m.noise_floor()
        fp = m.fp_rate_pct()
        gs = m.gyro_spike_pct()

        quality = []
        if nf is not None:
            if nf < 0.4:   quality.append("very low noise floor ✓")
            elif nf < 0.7: quality.append("acceptable noise floor")
            else:          quality.append("high noise floor ✗ — mount vibrates a lot")
        if fp is not None:
            if fp < 0.1:   quality.append("very few false positives ✓")
            elif fp < 0.5: quality.append("moderate false positives")
            else:          quality.append("many false positives ✗")
        if gs is not None:
            if gs > 5.0:   quality.append("frequent gyro spikes ✗ — mount slipping?")
            elif gs > 1.0: quality.append("occasional gyro spikes")

        a(f"  #{rank} {m.name}")
        a(f"     {' | '.join(quality) if quality else 'insufficient data'}")
        a(f"     {m.trip_count} trip(s), {m.total_moving} moving samples, "
          f"avg speed {m.mean_speed():.0f} km/h")
        a("")

    # Recommendations
    a("── RECOMMENDATIONS ───────────────────────────────────────────────────")
    a("")
    best = sorted_mounts[0] if sorted_mounts else None
    worst = sorted_mounts[-1] if len(sorted_mounts) > 1 else None

    if best and best.noise_floor() is not None:
        a(f"  Best mount so far:  {best.name}  (noise floor {best.noise_floor():.3f} Z)")
        a(f"  Use this as your reference for calibrating thresholds.")
        a("")

    if worst and worst != best and worst.noise_floor() is not None:
        a(f"  Worst mount so far: {worst.name}  (noise floor {worst.noise_floor():.3f} Z)")
        if worst.noise_floor() > 0.8:
            a(f"  ⚠  Very noisy — consider per-mount threshold scaling or a stiffer mount.")
        a("")

    a("  To collect more mount data: before each drive, tap the mount-type")
    a("  field in the app and choose from the list. Try at minimum:")
    a("    • Stiff/Rigid mount  (baseline reference)")
    a("    • Vent clip          (most common, likely noisier)")
    a("    • Dash suction cup   (compare resonance on rough roads)")
    a("")
    a("  If noise floor differs by >0.3 Z between mounts, add mount-specific")
    a("  threshold multipliers to DetectionConfig.")
    a("")
    a("=" * 74)

    text = "\n".join(lines)
    print("\n" + text)
    with open("mount_comparison_report.txt", "w") as f:
        f.write(text)
    print("\n✅  Saved to mount_comparison_report.txt")

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    print("\n📊  Mount Type Comparison Analysis")
    print("─" * 50)

    print("Fetching trips from Firestore…")
    trips = fetch_all_trips()
    print(f"\nFound {len(trips)} trip(s).\n")

    if not trips:
        print("No trips found. Check Firestore security rules.")
        return

    mount_stats   = {}   # mount_name -> MountStats
    trip_summary  = []

    for i, trip in enumerate(trips):
        raw_mount = trip.get("mountType") or trip.get("mount_type") or "Unknown"
        mount     = normalise_mount(raw_mount)
        scenario  = trip.get("scenario", "")
        vehicle   = trip.get("vehicle", "")
        doc_name  = trip.get("_doc_name", "")
        trip_id   = doc_name.split("/")[-1] if doc_name else str(i + 1)

        print(f"  Trip {i+1}/{len(trips)}  [{mount}]  {scenario or ''}  {vehicle or ''}")

        # Fetch samples — try subcollection first, then inline
        samples = fetch_samples_for_trip(doc_name) if doc_name else []
        if not samples:
            samples = trip.get("samples", []) or []
        if not isinstance(samples, list):
            samples = []

        print(f"    → {len(samples)} samples")

        trip_summary.append({
            "id":       i + 1,
            "mount":    mount,
            "scenario": scenario,
            "vehicle":  vehicle,
            "samples":  len(samples),
        })

        if mount not in mount_stats:
            mount_stats[mount] = MountStats(mount)

        ms = mount_stats[mount]
        ms.trip_count += 1
        for s in samples:
            if isinstance(s, dict):
                ms.add_sample(s)

    if not mount_stats:
        print("\nNo sample data found.")
        return

    total_samples = sum(m.total_moving for m in mount_stats.values())
    print(f"\nTotal moving samples analysed: {total_samples}")

    report(mount_stats, trip_summary)

if __name__ == "__main__":
    main()
