import json
import sqlite3
import pandas as pd
import numpy as np
import os
import time
from .core import Trip, IMU_HZ

class Exporter:
    @staticmethod
    def to_csv(trip: Trip, out_path: str):
        df = pd.DataFrame(trip.ground_truth)
        df.to_csv(out_path, index=False)
        print(f"Exported ground truth to {out_path}")

    @staticmethod
    def to_json(trip: Trip, out_path: str):
        """
        Exports to a format containing high-fidelity IMU arrays for Flutter replay,
        plus a downsampled 'samples' array matching Firestore trips collection.
        """
        # Create Firestore-compatible samples (1Hz)
        firestore_samples = []
        for i in range(len(trip.gps_time)):
            idx = int(trip.gps_time[i] * IMU_HZ)
            if idx < trip.num_samples:
                # Downsample vibration to max in that second
                start_idx = max(0, idx - IMU_HZ//2)
                end_idx = min(trip.num_samples, idx + IMU_HZ//2)
                # Compute smoothed vert accel similar to sensor_isolate
                vert = trip.az[start_idx:end_idx]
                vert_abs = np.abs(vert)
                accel_val = np.mean(vert_abs) # simple smoothing
                
                firestore_samples.append({
                    "lat": float(trip.gps_lat[i]),
                    "lon": float(trip.gps_lon[i]),
                    "accelVal": float(accel_val)
                })
        
        # High fidelity IMU for Flutter Replay
        data = {
            "duration_sec": trip.duration_sec,
            "vehicle": trip.vehicle.profile.name,
            "seed": trip.seed,
            "imu": {
                "ax": trip.ax.tolist(),
                "ay": trip.ay.tolist(),
                "az": trip.az.tolist()
            },
            "gps": {
                "lat": trip.gps_lat.tolist(),
                "lon": trip.gps_lon.tolist(),
                "speed": trip.gps_speed.tolist(),
                "accuracy": trip.gps_accuracy.tolist()
            },
            "samples": firestore_samples # Firestore format
        }
        
        with open(out_path, 'w') as f:
            json.dump(data, f)
        print(f"Exported JSON trace to {out_path}")

    @staticmethod
    def to_sqlite(trip: Trip, out_path: str):
        """
        Exports to SQLite matching the road_db.dart schema exactly.
        """
        if os.path.exists(out_path):
            os.remove(out_path)
            
        conn = sqlite3.connect(out_path)
        c = conn.cursor()
        
        # Create schema matching road_db.dart
        c.execute('''
          CREATE TABLE trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time INTEGER NOT NULL,
            end_time INTEGER,
            fidelity TEXT NOT NULL
          )
        ''')
        c.execute('''
          CREATE TABLE gps_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            speed REAL,
            accuracy REAL,
            accel_color TEXT,
            accel_val REAL,
            z_score REAL DEFAULT 0.0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''')
        c.execute('''
          CREATE TABLE accel_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            ax REAL NOT NULL,
            ay REAL NOT NULL,
            az REAL NOT NULL,
            vert_accel REAL,
            vert_accel_smoothed REAL,
            z_score REAL DEFAULT 0.0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''')
        
        start_ts = int(time.time() * 1000)
        c.execute("INSERT INTO trips (start_time, end_time, fidelity) VALUES (?, ?, ?)", 
                  (start_ts, start_ts + int(trip.duration_sec * 1000), 'high'))
        trip_id = c.lastrowid
        
        # Insert GPS
        gps_rows = []
        for i in range(len(trip.gps_time)):
            ts = start_ts + int(trip.gps_time[i] * 1000)
            gps_rows.append((trip_id, ts, float(trip.gps_lat[i]), float(trip.gps_lon[i]), 
                             float(trip.gps_speed[i]), float(trip.gps_accuracy[i]), 
                             'green', 1.0, 0.0))
        c.executemany('''
            INSERT INTO gps_samples (trip_id, ts, lat, lon, speed, accuracy, accel_color, accel_val, z_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', gps_rows)
        
        # Insert IMU (Subsampled to 15Hz to match UI rate or store full 100Hz)
        # To avoid massive DB size, let's store at 15Hz like the app does for UI, or full?
        # The app batches accel at full rate actually. Let's store full rate.
        accel_rows = []
        for i in range(trip.num_samples):
            ts = start_ts + int(trip.time[i] * 1000)
            ax, ay, az = float(trip.ax[i]), float(trip.ay[i]), float(trip.az[i])
            vert_abs = abs(az)
            accel_rows.append((trip_id, ts, ax, ay, az, vert_abs, vert_abs, 0.0))
            
            if len(accel_rows) > 10000:
                c.executemany('''
                    INSERT INTO accel_samples (trip_id, ts, ax, ay, az, vert_accel, vert_accel_smoothed, z_score)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ''', accel_rows)
                accel_rows = []
                
        if accel_rows:
            c.executemany('''
                INSERT INTO accel_samples (trip_id, ts, ax, ay, az, vert_accel, vert_accel_smoothed, z_score)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''', accel_rows)
            
        conn.commit()
        conn.close()
        print(f"Exported SQLite DB to {out_path}")
