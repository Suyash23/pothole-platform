# Requirements Verification Matrix

This document maps the core functional requirements of the **Road Quality Mapper (Pothole Finder)** application to their concrete implementation blocks in the codebase and verifies them using automated regression tests in [test/unit_test.dart](file:///Users/suyashpandya/Desktop/pothole_finder/test/unit_test.dart).

---

## Requirements Verification Registry

The following table registers each system requirement, identifies its source file/lines, and documents the matching verification test case.

| Requirement ID | Title | Description | Implementation File & Lines | Test Case Name |
| :--- | :--- | :--- | :--- | :--- |
| **F1** | **Vertical Acceleration Projection** | Projects 3D user-acceleration vectors onto a low-pass filtered gravity vector and removes gravity offset. | [sensor_isolate.dart:L180](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L180) | `Vertical Acceleration Projection` |
| **F2** | **Rolling Average Smoothing** | Applies a rolling average over a 0.75-second window to smooth out isolated sensor jitter. | [sensor_isolate.dart:L87-L91](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L87-L91)<br>[sensor_isolate.dart:L190-L197](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L190-L197) | `Rolling Average Window` |
| **F3** | **Z-Score Baseline Updates** | Updates a rolling 5-minute variance and standard deviation baseline using only valid non-stationary samples. | [sensor_isolate.dart:L79-L85](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L79-L85)<br>[sensor_isolate.dart:L252-L269](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L252-L269) | `Z-Score Tracking & updates` |
| **F4** | **Severity Color Mapping** | Maps Z-score variance to impact thresholds: Green (<2σ), Yellow (2σ-3σ), Orange (3σ-4σ), Red (≥4σ). | [sensor_isolate.dart:L313-L318](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L313-L318) | `Severity Color Mapping` |
| **F5** | **Douglas-Peucker Decimation** | Simplifies GPS paths on the map using a perpendicular distance decimation threshold ($\epsilon \approx 5$ meters). | [main.dart:L185-L220](file:///Users/suyashpandya/Desktop/pothole_finder/lib/main.dart#L185-L220)<br>[web_dashboard.dart:L116-L151](file:///Users/suyashpandya/Desktop/pothole_finder/lib/web_dashboard.dart#L116-L151) | `Douglas-Peucker Decimation` |


| **F8** | **Phone Handling Filters** | Suppresses calculations for 3 seconds upon detecting high angular rotation ($>2.0$ rad/s) or mount tilt shifts ($>10^{\circ}$). | [sensor_isolate.dart:L122-L132](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L122-L132)<br>[sensor_isolate.dart:L135-L166](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L135-L166) | `Phone Handling & Mount Stability suppression` |
| **F9** | **Adaptive Sensor Rates** | Switches from 25Hz baseline to 100Hz trigger rate when vibration exceeds 1.5σ Z-score; reverts after 1 second. | [sensor_isolate.dart:L94-L96](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L94-L96)<br>[sensor_isolate.dart:L201-L209](file:///Users/suyashpandya/Desktop/pothole_finder/lib/sensor_isolate.dart#L201-L209) | `Adaptive Sampling dynamic switching` |
| **F10**| **Local Storage & Syncing** | Stores raw IMU and GPS samples in local SQLite with fast WAL journal mode, and uploads trimmed trips to Cloud Firestore. | [road_db.dart](file:///Users/suyashpandya/Desktop/pothole_finder/lib/road_db.dart)<br>[recorder.dart:L118-L142](file:///Users/suyashpandya/Desktop/pothole_finder/lib/recorder.dart#L118-L142) | `SQLite Database Init and Batch Insertion` |

---

## Detailed Requirement Implementation Descriptions

### [F1] Vertical Acceleration Projection
Estimating pure road vibration requires projecting chassis acceleration along the vertical axis, ignoring horizontal cornering forces. We low-pass filter raw accelerometer readings to track the gravity axis vector $\vec{g}$:
$$\vec{g}_{new} = 0.95 \cdot \vec{g}_{old} + 0.05 \cdot \vec{a}_{raw}$$
Projecting the dynamic acceleration $\vec{a}_{dynamic}$ onto the unit vector $\hat{g}$ isolates pure vertical displacement:
$$\text{Acceleration}_{vertical} = |\vec{a}_{dynamic} \cdot \hat{g}|$$

### [F2] Rolling Average Smoothing
Individual high-frequency noise spikes are smoothed out by maintaining a double-ended queue (`Queue<AccelSample>`) representing the last 750 milliseconds. The smoothed vibration value $\bar{v}$ at time $t$ is calculated as:
$$\bar{v}(t) = \frac{1}{N}\sum_{i=1}^{N} v_i$$
where $N$ is the number of samples in the 750ms window.

### [F3] Z-Score Statistical Baselines
A rolling 5-minute statistical window maps road quality dynamically. This adapts to varying vehicle weights, suspensions, and tire pressures:
$$\mu = \frac{1}{M}\sum_{j=1}^{M} \bar{v}_j$$
$$\sigma = \sqrt{\frac{1}{M}\sum_{j=1}^{M} (\bar{v}_j - \mu)^2}$$
$$Z = \frac{\bar{v} - \mu}{\sigma}$$
*Standard deviation $\sigma$ is capped at a minimum of $0.001$ to avoid mathematical division-by-zero errors.*

### [F8] Phone Handling and Mount Stability Filters
Driving vibrations are easily polluted by the user picking up, rotating, or bumping the device.
*   **Rotation Suppression**: A gyroscope magnitude check triggers if $|\vec{\omega}| > 2.0 \, rad/s$.
*   **Mount Slippage Suppression**: The angular change between the current filtered gravity vector $\vec{g}$ and the oldest gravity vector in a 1-second history is measured:
    $$\theta = \arccos(\hat{g}_{current} \cdot \hat{g}_{old})$$
    If $\theta > 10.0^{\circ}$, suppression is triggered.
*   Upon trigger, vibration calculations are set to zero, and Z-score updates are frozen for $3,000 \, ms$.
