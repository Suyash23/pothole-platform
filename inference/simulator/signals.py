import numpy as np
import math

# Constants
IMU_HZ = 100
DT = 1.0 / IMU_HZ
GRAVITY = 9.81

class SignalGenerator:
    """Generates base IMU signals for various road and driving events."""
    
    @staticmethod
    def _create_time_array(duration_sec):
        return np.arange(0, duration_sec, DT)
        
    @staticmethod
    def _generate_bump_profile(duration_sec, amplitude, frequency, decay=0.0):
        t = SignalGenerator._create_time_array(duration_sec)
        signal = amplitude * np.sin(2 * np.pi * frequency * t)
        if decay > 0:
            signal *= np.exp(-decay * t)
        return t, signal

    @staticmethod
    def pothole(depth_cm=5.0, speed_kmh=50.0):
        """
        Simulates a pothole impact. A pothole usually has a sharp downward acceleration 
        followed by an upward spike and ringing.
        Duration depends on speed.
        """
        speed_ms = speed_kmh / 3.6
        # Rough heuristic: at 50kmh (13.8m/s), a 0.5m pothole takes 0.036s. 
        # The impact generates a spike proportional to depth.
        amplitude_g = (depth_cm / 2.0) * (speed_kmh / 50.0)
        
        duration = 0.4
        t = SignalGenerator._create_time_array(duration)
        # Sharp negative spike, followed by positive recoil, decaying
        freq = 15.0 # Hz of wheel bounce
        signal = -amplitude_g * np.sin(2 * np.pi * freq * t) * np.exp(-10 * t)
        return t, signal

    @staticmethod
    def speed_bump(height_cm=10.0, speed_kmh=20.0):
        """Simulates a speed bump. Upward heave followed by downward dip."""
        speed_ms = speed_kmh / 3.6
        amplitude_g = (height_cm / 5.0) * (speed_kmh / 20.0)
        
        duration = 0.8
        t = SignalGenerator._create_time_array(duration)
        freq = 3.0 # Slower heave than pothole
        signal = amplitude_g * np.sin(2 * np.pi * freq * t) * np.exp(-4 * t)
        return t, signal

    @staticmethod
    def manhole(depth_cm=2.0, speed_kmh=40.0):
        """Simulates a shallow manhole cover."""
        return SignalGenerator.pothole(depth_cm=depth_cm, speed_kmh=speed_kmh)

    @staticmethod
    def expansion_joint(speed_kmh=80.0):
        """High frequency, short duration click."""
        duration = 0.1
        t = SignalGenerator._create_time_array(duration)
        amplitude_g = 0.5 * (speed_kmh / 80.0)
        signal = amplitude_g * np.sin(2 * np.pi * 30 * t) * np.exp(-30 * t)
        return t, signal

    @staticmethod
    def rough_patch(duration_sec=2.0, severity=1.0, length_m=None, speed_kmh=None, roughness=None):
        """Continuous high-frequency noise for a duration."""
        if length_m is not None and speed_kmh is not None:
            speed_ms = speed_kmh / 3.6
            duration_sec = length_m / speed_ms if speed_ms > 0 else 2.0
            
        if roughness is not None:
            severity = roughness
            
        t = SignalGenerator._create_time_array(duration_sec)
        # Random noise filtered to simulate road vibration
        noise = np.random.normal(0, 0.2 * severity, len(t))
        return t, noise

    @staticmethod
    def hard_brake(decel_g=0.6, duration_sec=3.0):
        """Simulates hard braking. Primarily affects longitudinal accel (pitch)."""
        t = SignalGenerator._create_time_array(duration_sec)
        # Smooth step function
        signal = -decel_g * np.sin(np.pi * (t / duration_sec)) 
        return t, signal

    @staticmethod
    def aggressive_acceleration(accel_g=0.4, duration_sec=4.0):
        """Simulates hard acceleration."""
        t = SignalGenerator._create_time_array(duration_sec)
        signal = accel_g * np.sin(np.pi * (t / duration_sec))
        return t, signal

    @staticmethod
    def phone_handling(action="pickup"):
        """Simulates chaotic phone movement."""
        duration = 1.5
        t = SignalGenerator._create_time_array(duration)
        if action == "pickup":
            signal = 2.0 * np.sin(2 * np.pi * 2 * t) * np.exp(-2 * t)
        elif action == "drop":
            # Freefall (0g) followed by massive spike
            signal = np.zeros(len(t))
            signal[0:int(0.2*IMU_HZ)] = -1.0 # Freefall removes gravity
            signal[int(0.2*IMU_HZ):int(0.25*IMU_HZ)] = 5.0 # Impact
        elif action == "tap":
            duration = 0.1
            t = SignalGenerator._create_time_array(duration)
            signal = 0.5 * np.sin(2 * np.pi * 40 * t)
        return t, signal
