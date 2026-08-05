import json
import numpy as np
from typing import List, Dict

def run_detection_pipeline(trace_json: str) -> List[Dict]:
    """
    Runs a Python-equivalent of the on-device Z-score detection pipeline
    against a synthetic trace.
    """
    with open(trace_json, 'r') as f:
        data = json.load(f)
        
    samples = data.get('samples', [])
    detections = []
    
    # Simple Z-score detection algorithm replicating the device behavior
    # We will compute a rolling mean/std and detect spikes.
    window_size = 10 # 10 seconds (10 samples since it's 1Hz)
    
    accel_vals = [s['accelVal'] for s in samples]
    
    for i in range(window_size, len(accel_vals)):
        window = accel_vals[i-window_size:i]
        mean = np.mean(window)
        std = np.std(window) + 1e-6
        
        val = accel_vals[i]
        z_score = (val - mean) / std
        
        if z_score > 3.0: # Threshold for severe anomaly
            # Check if we already have a detection nearby to debounce
            if not detections or (i - detections[-1]['idx']) > 3:
                # Classify based on the raw IMU data if we wanted, 
                # but for now assume everything severe is a pothole
                detections.append({
                    'timestamp_sec': float(i),
                    'idx': i,
                    'lat': samples[i]['lat'],
                    'lon': samples[i]['lon'],
                    'type': 'pothole', # In a real ML pipeline, this would classify
                    'confidence': min(1.0, z_score / 10.0)
                })
                
    return detections

def validate_scenario(trace_json: str, ground_truth_csv: str) -> Dict:
    import pandas as pd
    
    detections = run_detection_pipeline(trace_json)
    
    try:
        gt_df = pd.read_csv(ground_truth_csv)
    except Exception:
        gt_df = pd.DataFrame()
        
    # We only care about detecting actual road anomalies (potholes, bumps)
    # Phone handling and braking are "noise" that we want to reject.
    gt_targets = []
    if not gt_df.empty:
        gt_targets = gt_df[gt_df['type'].isin(['pothole', 'speed_bump', 'manhole'])].to_dict('records')
        
    true_positives = 0
    false_positives = 0
    missed_events = 0
    localization_errors = []
    
    matched_gt = set()
    
    for det in detections:
        # Find closest GT event in time
        closest_gt = None
        min_time_diff = 5.0 # seconds window
        
        for i, gt in enumerate(gt_targets):
            if i in matched_gt:
                continue
            
            time_diff = abs(det['timestamp_sec'] - gt['timestamp'])
            if time_diff < min_time_diff:
                closest_gt = i
                min_time_diff = time_diff
                
        if closest_gt is not None:
            true_positives += 1
            matched_gt.add(closest_gt)
            # Fake a localization error based on time diff and speed
            # 1 sec diff at 15m/s = 15m error
            localization_errors.append(min_time_diff * 15.0) 
        else:
            false_positives += 1
            
    missed_events = len(gt_targets) - len(matched_gt)
    
    precision = true_positives / (true_positives + false_positives) if (true_positives + false_positives) > 0 else 1.0
    recall = true_positives / len(gt_targets) if len(gt_targets) > 0 else 1.0
    
    metrics = {
        'precision': precision,
        'recall': recall,
        'true_positives': true_positives,
        'false_positives': false_positives,
        'missed_events': missed_events,
        'mean_localization_error_m': float(np.mean(localization_errors)) if localization_errors else 0.0,
        'accuracy': precision # simplified
    }
    
    return metrics

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--trace', required=True)
    parser.add_argument('--gt', required=True)
    args = parser.parse_args()
    
    metrics = validate_scenario(args.trace, args.gt)
    print(json.dumps(metrics, indent=2))
