import numpy as np
import scipy.signal as signal
from dataclasses import dataclass
from typing import List, Dict, Any, Tuple
import math
from .signals import SignalGenerator, IMU_HZ, DT

@dataclass
class VehicleProfile:
    name: str
    natural_freq_hz: float
    damping_ratio: float

VEHICLES = {
    "SEDAN": VehicleProfile("SEDAN", 1.2, 0.3),
    "SUV": VehicleProfile("SUV", 1.0, 0.35),
    "TRUCK": VehicleProfile("TRUCK", 2.0, 0.2),
    "SPORTS_CAR": VehicleProfile("SPORTS_CAR", 2.5, 0.6),
    "MOTORCYCLE": VehicleProfile("MOTORCYCLE", 3.0, 0.7),
}

class Vehicle:
    def __init__(self, profile_name: str):
        if profile_name not in VEHICLES:
            profile_name = "SEDAN"
        self.profile = VEHICLES[profile_name]
        
    def apply_suspension(self, raw_vertical_accel: np.ndarray) -> np.ndarray:
        """
        Applies a 2nd-order lowpass filter representing the vehicle suspension.
        Transfer function: H(s) = w_n^2 / (s^2 + 2*zeta*w_n*s + w_n^2)
        """
        wn = 2 * np.pi * self.profile.natural_freq_hz
        zeta = self.profile.damping_ratio
        
        # Continuous-time transfer function
        num = [wn**2]
        den = [1.0, 2*zeta*wn, wn**2]
        
        # Convert to discrete-time using bilinear transform
        sys_c = signal.TransferFunction(num, den)
        sys_d = sys_c.to_discrete(DT, method='bilinear')
        
        # Apply filter using lfilter
        b, a = sys_d.num, sys_d.den
        filtered = signal.lfilter(b, a, raw_vertical_accel)
        return filtered

@dataclass
class RoadEvent:
    timestamp_sec: float
    event_type: str
    params: Dict[str, Any]

class Trip:
    def __init__(self, duration_sec: float, vehicle_type: str, seed: int = 42, **kwargs):
        self.duration_sec = duration_sec
        self.vehicle = Vehicle(vehicle_type)
        self.seed = seed
        self.events: List[RoadEvent] = []
        np.random.seed(self.seed)
        
        self.start_lat = kwargs.get('start_lat', 37.7749)
        self.start_lon = kwargs.get('start_lon', -122.4194)
        self.heading_deg = kwargs.get('heading_deg', 45.0)
        
        # Output arrays
        self.num_samples = int(self.duration_sec * IMU_HZ)
        self.time = np.arange(0, self.duration_sec, DT)
        
        # IMU Components
        self.ax = np.zeros(self.num_samples)
        self.ay = np.zeros(self.num_samples)
        self.az = np.ones(self.num_samples) # Gravity base
        
        # GPS Components (1Hz)
        self.gps_time = np.arange(0, self.duration_sec, 1.0)
        self.gps_lat = np.zeros(len(self.gps_time))
        self.gps_lon = np.zeros(len(self.gps_time))
        self.gps_speed = np.zeros(len(self.gps_time))
        self.gps_accuracy = np.ones(len(self.gps_time)) * 5.0
        
        self.ground_truth = []

    def add_event(self, event: RoadEvent):
        self.events.append(event)
        
    def _inject_signal(self, base_array: np.ndarray, timestamp: float, sig: np.ndarray):
        start_idx = int(timestamp * IMU_HZ)
        end_idx = start_idx + len(sig)
        if start_idx >= self.num_samples:
            return
        
        if end_idx > self.num_samples:
            sig = sig[:self.num_samples - start_idx]
            end_idx = self.num_samples
            
        base_array[start_idx:end_idx] += sig

    def simulate(self):
        # 1. Base driving noise
        self.az += np.random.normal(0, 0.05, self.num_samples)
        
        # 2. Inject Events
        for ev in self.events:
            self.ground_truth.append({
                'timestamp': ev.timestamp_sec,
                'type': ev.event_type,
                **ev.params
            })
            
            if ev.event_type == 'pothole':
                t, sig = SignalGenerator.pothole(**ev.params)
                self._inject_signal(self.az, ev.timestamp_sec, sig)
            elif ev.event_type == 'speed_bump':
                t, sig = SignalGenerator.speed_bump(**ev.params)
                self._inject_signal(self.az, ev.timestamp_sec, sig)
            elif ev.event_type == 'manhole':
                t, sig = SignalGenerator.manhole(**ev.params)
                self._inject_signal(self.az, ev.timestamp_sec, sig)
            elif ev.event_type == 'expansion_joint':
                t, sig = SignalGenerator.expansion_joint(**ev.params)
                self._inject_signal(self.az, ev.timestamp_sec, sig)
            elif ev.event_type == 'rough_patch':
                t, sig = SignalGenerator.rough_patch(**ev.params)
                self._inject_signal(self.az, ev.timestamp_sec, sig)
            elif ev.event_type == 'hard_brake':
                t, sig = SignalGenerator.hard_brake(**ev.params)
                self._inject_signal(self.ay, ev.timestamp_sec, sig)
            elif ev.event_type == 'aggressive_acceleration':
                t, sig = SignalGenerator.aggressive_acceleration(**ev.params)
                self._inject_signal(self.ay, ev.timestamp_sec, sig)
            elif ev.event_type == 'lane_change':
                # Lateral accel (ax)
                duration = 3.0
                t = np.arange(0, duration, DT)
                sig = 0.2 * np.sin(2 * np.pi * (1/duration) * t)
                self._inject_signal(self.ax, ev.timestamp_sec, sig)
            elif ev.event_type == 'phone_handling':
                t, sig = SignalGenerator.phone_handling(**ev.params)
                # Apply to all axes chaotically
                self._inject_signal(self.ax, ev.timestamp_sec, sig * np.random.rand())
                self._inject_signal(self.ay, ev.timestamp_sec, sig * np.random.rand())
                self._inject_signal(self.az, ev.timestamp_sec, sig)
                
        # 3. Apply Suspension (only to z-axis for road events, ideally)
        # We apply it to the whole Z array, excluding gravity and phone handling if we were perfectly accurate,
        # but for simplicity we filter the AC component of az
        az_ac = self.az - 1.0
        az_filtered = self.vehicle.apply_suspension(az_ac)
        self.az = az_filtered + 1.0
        
        # 4. Generate Kinematics (GPS)
        base_lat, base_lon = self.start_lat, self.start_lon
        speed_ms = 15.0 # 54 km/h baseline
        heading_rad = math.radians(self.heading_deg)
        
        for i in range(len(self.gps_time)):
            dist = speed_ms * 1.0 # 1 sec step
            
            # Simple spherical approximation
            delta_lat = (dist * math.cos(heading_rad)) / 111000.0
            delta_lon = (dist * math.sin(heading_rad)) / (111000.0 * math.cos(math.radians(base_lat)))
            
            base_lat += delta_lat
            base_lon += delta_lon
            
            self.gps_lat[i] = base_lat
            self.gps_lon[i] = base_lon
            self.gps_speed[i] = speed_ms
            
        # 5. Sensor Noise & Gravity Drift
        drift = np.linspace(0, 0.02, self.num_samples)
        self.ax += drift
        self.ay += drift
        
        return self
