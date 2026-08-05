from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
import os
import glob
import json

from .cli import load_scenario
from .export import Exporter
from .validation import validate_scenario

app = FastAPI(title="Pothole Simulator API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # For local development
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SCENARIOS_DIR = os.path.join(os.path.dirname(__file__), "scenarios")
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "out")

os.makedirs(OUT_DIR, exist_ok=True)

@app.get("/scenarios")
def list_scenarios():
    scenarios = []
    for path in glob.glob(os.path.join(SCENARIOS_DIR, "*.yaml")):
        base = os.path.basename(path)
        name = os.path.splitext(base)[0]
        scenarios.append({"id": name, "file": base})
    return {"scenarios": scenarios}

@app.post("/simulate/{scenario_id}")
def simulate_scenario(scenario_id: str):
    yaml_path = os.path.join(SCENARIOS_DIR, f"{scenario_id}.yaml")
    if not os.path.exists(yaml_path):
        raise HTTPException(status_code=404, detail="Scenario not found")
        
    trip = load_scenario(yaml_path)
    trip.simulate()
    
    json_path = os.path.join(OUT_DIR, f"{scenario_id}.json")
    sqlite_path = os.path.join(OUT_DIR, f"{scenario_id}.db")
    csv_path = os.path.join(OUT_DIR, f"{scenario_id}_ground_truth.csv")
    
    Exporter.to_json(trip, json_path)
    Exporter.to_sqlite(trip, sqlite_path)
    Exporter.to_csv(trip, csv_path)
    
    metrics = validate_scenario(json_path, csv_path)
    
    return {
        "status": "success",
        "scenario_id": scenario_id,
        "metrics": metrics
    }

@app.get("/data/{scenario_id}")
def get_trace_data(scenario_id: str):
    json_path = os.path.join(OUT_DIR, f"{scenario_id}.json")
    if not os.path.exists(json_path):
        raise HTTPException(status_code=404, detail="Data not generated yet. Please simulate first.")
        
    with open(json_path, 'r') as f:
        data = json.load(f)
        
    csv_path = os.path.join(OUT_DIR, f"{scenario_id}_ground_truth.csv")
    import pandas as pd
    if os.path.exists(csv_path):
        df = pd.read_csv(csv_path)
        df = df.astype(object).where(pd.notnull(df), None)
        gt = df.to_dict(orient='records')
        data['ground_truth'] = gt
    else:
        data['ground_truth'] = []
        
    return data
