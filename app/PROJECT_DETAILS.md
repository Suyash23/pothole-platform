# Road Quality Mapper (Pothole Finder) - Project Details

This document outlines the project details, core algorithms, data storage, retrieval mechanics, and the web dashboard of the **Road Quality Mapper** system.

---

## 1. Project Idea

The **Road Quality Mapper** (Pothole Finder) is a dual-surface Flutter application designed to measure and map road surface quality dynamically. The system leverages built-in smartphone sensors (accelerometer, gyroscope, GPS) to map road defects and overall vibration intensity in real-time.

### Key Objectives:
- **Passive Crowd-Sourced Mapping:** Gather road quality data passively as users drive, without requiring dedicated scanning hardware.
- **On-Device Edge Processing:** Process high-frequency sensor readings locally in real-time using background threads (isolates) to reduce data payloads and preserve UI responsiveness.
- **Visual Heatmaps:** Color-code traveled paths (green/yellow/red) based on vibration thresholds and present them on an interactive map.
- **Cloud Synchronization:** Store trip data locally on SQLite first to prevent data loss due to network dropouts, then sync atomically to Cloud Firestore on trip completion for web visualization.

---

## 2. Current Way to Detect Bumps (Core Algorithms)

To distinguish actual road anomalies (potholes, rough patches) from vehicular cabin movement, device re-orientations, and speed changes, the system uses a digital signal processing pipeline:

```
IMU Event ──► Gravity Projection ──► Rolling Average ──► Rolling Z-Score ──► Thresholding & Cooldowns
```

### A. Vertical Acceleration Projection (Gravity Rotation)
Since the user's phone might be mounted at any arbitrary angle in the vehicle, raw Z-axis accelerometer values do not represent true vertical suspension movement.
1. The app computes a rolling average gravity vector $\vec{g}$ using accelerometer readings during stable/quiet periods.
2. The dynamic user acceleration $\vec{a}_{\text{user}}$ is projected onto the normalized gravity vector $\vec{u}_g = \frac{\vec{g}}{\|\vec{g}\|}$:
   $$\text{vertAccel} = \vec{a}_{\text{user}} \cdot \vec{u}_g$$
*This isolates vertical vibration regardless of the phone's tilt/orientation.*

### B. Rolling Average Vibration Smoothing
To eliminate high-frequency engine vibrations and minor sensor noise, the vertical acceleration undergoes a sliding window average. The window duration is set to **750 milliseconds**.

### C. 5-Minute Rolling Z-Score Baseline
Fixed thresholds fail because a gravel road produces higher baseline vibration than a smooth concrete highway. To adapt, the system uses a **5-minute sliding baseline**:
1. It computes the sliding mean ($\mu$) and standard deviation ($\sigma$) of the smoothed vertical vibration values over the last 5 minutes.
2. For each incoming sample $x$, the Z-score is calculated:
   $$Z = \frac{x - \mu}{\sigma}$$
*This dynamic Z-score represents how anomalous a bump is relative to the current road context.*

### D. Anomaly Detection Thresholds & Events
All thresholds are defined in `DetectionConfig` and trigger specific events:

| Event Type | Trigger Condition | Cooldown | Description |
| :--- | :--- | :--- | :--- |
| **Pothole** | $Z \geq 4.0$ | 3 seconds | Sudden, severe impact (e.g., hitting a pothole). |
| **Rough Road** | $Z \geq 3.0$ sustained for $\geq 3$s (1s grace gap allowed) | 10 seconds | Extended stretches of cracked/deteriorated pavement. |
| **Sudden Braking** | Horizontal acceleration $> 0.35$ g (300 ms low-pass) | 4 seconds | High-deceleration events. |
| **Manual Tapping** | User presses a manual annotation button on-screen | None | User-flagged road hazard. |

### E. Suppression Rules
To avoid false positives, the anomaly detectors are automatically suppressed if:
* **Speed Gate:** The vehicle's speed falls below the threshold (typically 10-15 km/h).
* **High Gyroscope Noise:** The gyroscope magnitude exceeds a preset threshold (meaning the user is adjusting the phone or the mount is shaking loose).
* **Gravity Drift:** The gravity vector shifts more than a stable angle within a short window, indicating a change in phone mounting orientation.

---

## 3. Data Storage & Retrieval

The system employs a offline-first hybrid storage strategy:

```
Raw Sensors ──► Local SQLite ──► (On Trip Stop) ──► Cloud Firestore ──► Web Dashboard
```

### A. Local Storage (SQLite Database)
During active recording, raw and processed samples are written in batches (every 1.5 seconds) to a local SQLite database (`sqflite` package). This guarantees that data is not lost if the app crashes, the battery dies, or the network drops.

The schema consists of three tables:
1. **`trips`**: Metadata for each recording session.
   * `id` (Primary Key)
   * `startTimeMs` & `endTimeMs`
   * `fidelity` (High: GPS 1Hz/IMU 100Hz, Medium: 0.5Hz/50Hz, Low: 0.2Hz/20Hz)
   * `scenario`, `vehicle`, and `mountType`
2. **`gps_samples`**: Segmented geographical logs.
   * `ts` (timestamp), `lat` (latitude), `lon` (longitude), `speed`, `accuracy`
   * `color` (green/yellow/red based on Z-score intensity)
   * `z_score`, `accelVal`
   * Flags: `is_braking`, `is_tapping`
3. **`accel_samples`**: High-frequency raw sensor readings used for sandbox testing and offline algorithm replay.

### B. Remote Cloud Storage (Cloud Firestore)
Once the user stops a trip, the app performs an atomic upload to **Cloud Firestore**.
* **Collection:** `trips`
* **Document Schema:** Each document represents a trip, storing the trip metadata alongside an array of serialized `gps_samples` maps inside the document.

### C. Data Retrieval
* **Local Retrieval:** The mobile app queries SQLite (`road_db.dart`) to populate the local trip history list and load previous runs for sandbox replay.
* **Remote Retrieval:** The web dashboard and shared clients fetch data directly from Firestore by listening to streams or querying the `trips` collection.

---

## 4. Web Dashboard Details

The **Road Quality Global Dashboard** provides a unified, read-only web view of all synchronized trip data.

### Technical Stack & Dependencies:
* **Framework:** Flutter Web (`web_dashboard.dart`)
* **Database Connection:** `cloud_firestore` (Direct query and real-time streams)
* **Map Engine:** `flutter_map` backed by OpenStreetMap tiles (`TileLayer`)
* **Vector Math & Algorithms:** `latlong2` and custom geometry operations

### Core Features of the Web App:
1. **Real-time Map Synchronization:** Displays all paths registered on Cloud Firestore. The paths are split dynamically by color depending on the road quality rating recorded at each coordinate.
2. **Douglas-Peucker Path Decimation:** High-frequency GPS logging generates thousands of points, which can degrade web browser performance. The dashboard runs the Douglas-Peucker algorithm on-the-fly with an $\epsilon \approx 5$ meters to decimate points without losing the visual outline of the road quality.
3. **Smart Segment Splitting:** To avoid drawing straight lines across oceans or continents between disconnected tracking sessions, the visualizer splits polylines if:
   * The time gap between samples exceeds **10 seconds**.
   * The distance between points exceeds **100 meters**.
4. **Interactive Filters:**
   * **Date Range Filter:** Uses an overlays-driven calendar (`showDateRangePicker`) to display only trips recorded within a specific timeline.
5. **Quick-Center Navigation:** A floating action button instantly re-centers and zooms the viewport over the primary dataset coordinates.
