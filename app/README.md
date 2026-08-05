# Road Quality Mapper (Flutter)

## What it does
- Records GPS path and accelerometer data during a user-controlled trip.
- Computes vertical vibration intensity and smooths it with a rolling average.
- Colors map segments green/yellow/red based on intensity thresholds.
- Stores everything locally in SQLite.

## Notes
- Fidelity presets: High (GPS 1 Hz, accel 100 Hz), Medium (0.5 Hz, 50 Hz), Low (0.2 Hz, 20 Hz).
- Vertical acceleration is estimated by projecting onto the gravity axis and removing 9.81 m/s².
- Rolling average window is 0.75 seconds.

## Basic test strategy
- Unit tests: verify rolling average window and threshold color mapping.
- Integration tests: simulate time-based sampling to ensure expected insert counts.
- UI tests: start/stop transitions and fidelity toggles update state.

## Battery considerations
- High fidelity can be power heavy. Consider auto-pausing when stationary.
- Batch UI updates and avoid re-rendering the map at accelerometer rates.
- Use OS-optimized location streams or reduce GPS frequency when idle.

## iOS Build Instructions
- To avoid the "Unable to flip between RX and RW memory protection" error on physical iOS 14+ devices, you must build the app in profile mode (which disables the JIT compiler):
  `flutter run --profile`
- Always run `./scripts/doctor.sh` before building to ensure your environment matches the pinned versions in `TOOLCHAIN.md`.
