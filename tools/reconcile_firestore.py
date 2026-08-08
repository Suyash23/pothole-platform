#!/usr/bin/env python3
"""
Reconcile orphaned / unfinalized Firestore trip documents.
===========================================================
The old upload path minted a fresh trip doc on every retry, so interrupted
uploads left behind duplicate and empty documents (uploadComplete != true).
This tool finds them and, ONLY with an explicit flag, deletes the empty ones.

Classification (based on the ACTUAL samples/events subcollections, never the
parent doc's self-reported sampleCount, which can be wrong):

  KEEP                    uploadComplete == true                 → never touched
  EMPTY ORPHAN            not complete, 0 samples AND 0 events   → safe to delete
  SUPERSEDED             not complete, has data, but a COMPLETE doc for the same
                          drive exists (same start time ± window, comparable size)
                          → data is safely duplicated elsewhere, safe to delete
  UNFINALIZED (UNIQUE)   not complete, has data, and NO complete copy exists
                          → the only copy → REPORTED only, never deleted.

Usage:
    python3 reconcile_firestore.py                   # dry run (read-only, default)
    python3 reconcile_firestore.py --delete-empty        # delete EMPTY orphans
    python3 reconcile_firestore.py --delete-superseded   # delete SUPERSEDED partials
    python3 reconcile_firestore.py --delete-empty --delete-superseded

Recommended order: delete empties now; open the app so it re-uploads the unique
partials into clean complete docs; re-run and --delete-superseded to clear the
old partials once a complete copy exists. Deletion is irreversible.
"""
import sys
from datetime import datetime

try:
    import requests
except ImportError:
    sys.exit("pip install requests")

# Firestore rules require a signed-in caller (they were world-open until
# 2026-08-04). SESSION carries the anonymous ID token.
from fetch_firebase_analysis import SESSION

PROJECT_ID = "pothole-finder-e323f"
API_KEY = "AIzaSyBvM3i-F0vQKDhjWv8_B80kE2HMe8glhVs"
BASE = f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents"

DELETE_EMPTY = "--delete-empty" in sys.argv
DELETE_SUPERSEDED = "--delete-superseded" in sys.argv

# A partial doc counts as superseded by a complete doc when their start times are
# within this window and the complete doc holds a comparable share of the data.
SUPERSEDE_WINDOW_MS = 120_000
SUPERSEDE_MIN_RATIO = 0.5


def fv(v):
    if not isinstance(v, dict):
        return v
    if "stringValue" in v: return v["stringValue"]
    if "integerValue" in v: return int(v["integerValue"])
    if "doubleValue" in v: return float(v["doubleValue"])
    if "booleanValue" in v: return bool(v["booleanValue"])
    if "nullValue" in v: return None
    if "timestampValue" in v: return v["timestampValue"]
    if "arrayValue" in v: return [fv(i) for i in v["arrayValue"].get("values", [])]
    if "mapValue" in v: return {k: fv(x) for k, x in v["mapValue"].get("fields", {}).items()}
    return v


def d2d(doc):
    return {k: fv(v) for k, v in doc.get("fields", {}).items()}


def fetch_trips():
    trips, token = [], None
    while True:
        url = f"{BASE}/trips?key={API_KEY}&pageSize=50"
        if token:
            url += f"&pageToken={token}"
        r = SESSION.get(url, timeout=30)
        r.raise_for_status()
        data = r.json()
        for doc in data.get("documents", []):
            d = d2d(doc)
            d["_id"] = doc.get("name", "").split("/")[-1]
            trips.append(d)
        token = data.get("nextPageToken")
        if not token:
            break
    return trips


def subcollection_stats(trip_id, name):
    """Return (doc_count, sample_count) for a trip's subcollection."""
    docs, samples, token = 0, 0, None
    while True:
        url = f"{BASE}/trips/{trip_id}/{name}?key={API_KEY}&pageSize=50"
        if token:
            url += f"&pageToken={token}"
        r = SESSION.get(url, timeout=30)
        if r.status_code != 200:
            break
        data = r.json()
        for doc in data.get("documents", []):
            docs += 1
            batch = d2d(doc).get("samples", [])
            if isinstance(batch, list):
                samples += len(batch)
        token = data.get("nextPageToken")
        if not token:
            break
    return docs, samples


def day(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return "?"


def delete_doc(trip_id):
    url = f"{BASE}/trips/{trip_id}?key={API_KEY}"
    r = SESSION.delete(url, timeout=30)
    return r.status_code in (200, 204)


def main():
    print("Fetching trips…")
    trips = fetch_trips()
    incomplete = [t for t in trips if not t.get("uploadComplete")]
    # Complete docs are the potential "supersedes" for a partial: (startTimeMs, sampleCount)
    complete = [(int(t.get("startTimeMs") or 0), int(t.get("sampleCount") or 0))
                for t in trips if t.get("uploadComplete")]
    print(f"{len(trips)} trips total: {len(complete)} complete, {len(incomplete)} not.\n"
          f"Inspecting subcollections of the {len(incomplete)} incomplete docs…\n")

    def superseded_by(start_ms, real_samples):
        for c_start, c_count in complete:
            if abs(c_start - start_ms) <= SUPERSEDE_WINDOW_MS and \
               c_count >= SUPERSEDE_MIN_RATIO * real_samples:
                return True
        return False

    empty, superseded, unique = [], [], []
    for t in sorted(incomplete, key=lambda x: int(x.get("startTimeMs") or 0)):
        tid = t["_id"]
        start_ms = int(t.get("startTimeMs") or 0)
        sbatch, scount = subcollection_stats(tid, "samples")
        ebatch, _ = subcollection_stats(tid, "events")
        row = (tid, day(start_ms), sbatch, scount, ebatch)
        if sbatch == 0 and ebatch == 0:
            empty.append(row)
        elif superseded_by(start_ms, scount):
            superseded.append(row)
        else:
            unique.append(row)

    def show(title, rows):
        print(f"── {title} ({len(rows)}) " + "─" * max(0, 42 - len(title)))
        if not rows:
            print("  (none)")
        for tid, d, sb, sc, eb in rows:
            print(f"  {tid:22} {d:16}  sampleBatches={sb:<3} samples={sc:<5} eventDocs={eb}")
        print()

    show("EMPTY ORPHANS — safe to delete", empty)
    show("SUPERSEDED BY A COMPLETE COPY — safe to delete", superseded)
    show("UNFINALIZED, UNIQUE — the only copy, NOT deleted", unique)

    if unique:
        print("  ⚠️  These are real drives with no complete copy yet. NOT deleted.")
        print("      Open the app so it re-uploads them (v14 fix), then re-run: they")
        print("      will move to SUPERSEDED and --delete-superseded can clear them.\n")

    def maybe_delete(label, rows, enabled):
        if not enabled:
            print(f"DRY RUN: {len(rows)} {label} would be deleted.")
            return
        print(f"Deleting {len(rows)} {label}…")
        ok = 0
        for tid, *_ in rows:
            if delete_doc(tid):
                ok += 1
                print(f"  deleted {tid}")
            else:
                print(f"  FAILED  {tid}")
        print(f"  → deleted {ok}/{len(rows)}.")

    maybe_delete("empty orphan(s)", empty, DELETE_EMPTY)
    maybe_delete("superseded partial(s)", superseded, DELETE_SUPERSEDED)
    if not (DELETE_EMPTY or DELETE_SUPERSEDED):
        print("\nRe-run with --delete-empty and/or --delete-superseded to act (irreversible).")


if __name__ == "__main__":
    main()
