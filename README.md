# Pothole Platform

Road-surface defect detection: a phone collects and classifies road events while
driving, a Python service replays and analyses that data, and a web dashboard
shows the results.

All four components talk to the **same Firebase project — `pothole-finder-e323f`**.
They used to live in four separate Desktop folders (two of them sharing one
GitHub remote with unrelated histories, which is why `main` never made sense);
this repo consolidates them.

## Layout

| Path | What it is | Stack |
|---|---|---|
| `app/` | Phone app: records drives, runs the on-device detector, uploads samples/events/telemetry to Firestore | Flutter / Dart |
| `inference/` | Replay + simulation service and its UI | Python (FastAPI) + React/TS |
| `dashboard/` | Web dashboard over the collected drives | React + Vite |
| `tools/` | Drive-analysis scripts — pull data from Firestore and score the detector against driver labels | Python |
| `firebase/` | Shared Firestore security rules | — |
| `archive/` | Superseded code kept for reference only | — |

## How the pieces connect

```
  app/ (phone)                    tools/ (analysis)
      │ records drives                  │ pulls trips + telemetry
      │ classifies events               │ re-scores detector thresholds
      ▼                                 ▼
  ┌─────────────────────────────────────────────┐
  │   Firestore — project pothole-finder-e323f  │
  │   trips/{id}/samples, events,               │
  │              lc_diag, impulse_diag          │
  └─────────────────────────────────────────────┘
      ▲                                 │
      │ replay / simulate               │ reads
  inference/                        dashboard/
```

## Getting started

**app/** — Flutter, needs the Flutter SDK:
```bash
cd app && flutter pub get && flutter test
```

**dashboard/** — Vite dev server:
```bash
cd dashboard && npm install && npm run dev
```

**inference/** — FastAPI service:
```bash
cd inference && python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt && python main.py
```

**tools/** — analysis scripts (need `requests`), run from `tools/`:
```bash
cd tools && python3 fetch_impulse_diags.py 2026-08-04
```

## Security

### Access model

Firestore was `allow read, write: if true` — unauthenticated read *and write*
from anywhere — until 2026-08-04. Every recorded drive was world-readable and
world-destroyable. The project id offers no protection: it ships inside every
build of the app.

Now the app, the dashboard and the `tools/` scripts all **sign in anonymously**,
and `firebase/firestore.rules` requires a uid. Trips are stamped with the
creating device's `ownerUid`; only that device can update or delete a trip or
write to its subcollections. Reads are open to any signed-in client, because
the dashboard and analysis scripts need to see every drive.

### Deploying the rules — ORDER MATTERS

Deploying the rules before a build carrying `firebase_auth` reaches the phone
will break uploads (the app writes with no uid and is denied):

1. Ship the app (`app/`) with anonymous sign-in, and confirm a drive uploads.
2. Enable **Anonymous** sign-in: Firebase console → Authentication → Sign-in
   method. Nothing works until this is on.
3. Deploy the dashboard so it signs in too.
4. Only then: `firebase deploy --only firestore:rules`

Trips recorded before this change have no `ownerUid`. They stay readable and
become immutable — no client can claim or edit them. Delete them from the
console if they need to go.

### Credentials

`inference/` authenticates with a **service-account key** at
`inference/firebase-credentials.json`. It is **gitignored and must stay that
way** — it grants admin access, and the Admin SDK bypasses the rules above
entirely. It is not in this repo's history. Rotate it if it has ever been
shared (*Project settings → Service accounts → Generate new private key*).

The `AIza…` values in `app/lib/firebase_options.dart`,
`app/ios/Runner/GoogleService-Info.plist` and `dashboard/src/firebase.js` are
Firebase **client** API keys. These are public by design — they identify the
project and ship in every distributed build. Secret scanners flag them; they do
not need rotating, and rotating them protects nothing. Restrict them instead
(Google Cloud console → Credentials → API key → application restrictions:
iOS bundle id, Android package, HTTP referrer).

`tools/` caches its anonymous token at `~/.pothole_platform_auth.json`,
deliberately outside the repo. It holds a refresh token — treat it as a
credential.

## Detector tuning

The detector's thresholds are derived from labelled drives, and the reasoning
behind each one lives in the constants' doc comments in
`app/lib/models.dart` (`DetectionConfig`) — including the ones that were tried
and reverted, and why. Read those before changing a number.

The loop is: drive and correct alerts in-app → `tools/fetch_impulse_diags.py`
and `tools/fetch_lc_diags.py` pull the per-decision telemetry → re-score
candidate thresholds against the driver's labels. Detector logic lives in
`app/lib/detection/detector.dart` and is unit-tested in `app/test/`.

## History

`app/` and `dashboard/` were separate git repositories; both histories are
preserved here (the graph has two roots, which is expected). `inference/` and
`archive/legacy-static-dashboard/` were never under version control and enter
with a single commit.

`archive/legacy-static-dashboard/` is the original 175-line static dashboard
that `dashboard/` replaced. Kept for reference; not deployed.
