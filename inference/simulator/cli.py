import argparse
import yaml
import os
import sys
from .core import Trip, RoadEvent
from .export import Exporter

def load_scenario(yaml_path: str) -> Trip:
    with open(yaml_path, 'r') as f:
        data = yaml.safe_load(f)
        
    duration = data.get('duration_sec', 60.0)
    vehicle = data.get('vehicle', 'SEDAN')
    seed = data.get('seed', 42)
    start_lat = data.get('start_lat', 37.7749)
    start_lon = data.get('start_lon', -122.4194)
    heading_deg = data.get('heading_deg', 45.0)
    
    trip = Trip(duration, vehicle, seed, start_lat=start_lat, start_lon=start_lon, heading_deg=heading_deg)
    
    for ev in data.get('events', []):
        event = RoadEvent(
            timestamp_sec=ev['timestamp_sec'],
            event_type=ev['type'],
            params=ev.get('params', {})
        )
        trip.add_event(event)
        
    return trip

def main():
    parser = argparse.ArgumentParser(description="Synthetic Sensor Trace Generator")
    parser.add_argument('command', choices=['run'], help="Command to execute")
    parser.add_argument('scenario', help="Path to scenario YAML file")
    parser.add_argument('--output', default='out', help="Output directory")
    
    args = parser.parse_args()
    
    if args.command == 'run':
        print(f"Loading scenario from {args.scenario}...")
        trip = load_scenario(args.scenario)
        
        print("Simulating physics...")
        trip.simulate()
        
        os.makedirs(args.output, exist_ok=True)
        base_name = os.path.splitext(os.path.basename(args.scenario))[0]
        
        json_path = os.path.join(args.output, f"{base_name}.json")
        sqlite_path = os.path.join(args.output, f"{base_name}.db")
        csv_path = os.path.join(args.output, f"{base_name}_ground_truth.csv")
        
        Exporter.to_json(trip, json_path)
        Exporter.to_sqlite(trip, sqlite_path)
        Exporter.to_csv(trip, csv_path)
        
        print(f"✅ Scenario '{base_name}' generated successfully.")

if __name__ == '__main__':
    main()
