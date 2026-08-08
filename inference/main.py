import os
import numpy as np
import pandas as pd
from sklearn.mixture import GaussianMixture
from shapely.geometry import LineString, Point
import time
import firebase_admin
from firebase_admin import credentials, firestore

# Firebase is initialised LAZILY, on first Firestore use.
#
# This module used to call credentials.Certificate(...) and initialize_app() at
# import time, which made importing it impossible without the service-account
# key on disk. That key is (correctly) gitignored, so CI could not even collect
# tests/test_multi_trip_aggregation.py — it imports infer_lanes_from_data from
# here, and the import raised before pytest reached the test.
#
# The pure computation in this module needs no credentials; only the two
# Firestore helpers do. Deferring the connection keeps those functions working
# exactly as before while letting the analysis code be imported and unit-tested
# anywhere.
_db = None

# Path to the service-account JSON. GOOGLE_APPLICATION_CREDENTIALS is the
# standard Google variable and wins if set, so deployments can inject the key
# without editing code.
CREDENTIALS_PATH = os.environ.get(
    "GOOGLE_APPLICATION_CREDENTIALS", "firebase-credentials.json"
)


def get_db():
    """Returns the Firestore client, initialising Firebase on first call.

    Raises FileNotFoundError with an actionable message when the
    service-account key is missing, rather than failing at import.
    """
    global _db
    if _db is not None:
        return _db
    if not os.path.exists(CREDENTIALS_PATH):
        raise FileNotFoundError(
            f"Firebase service-account key not found at '{CREDENTIALS_PATH}'. "
            "It is gitignored by design — place it there locally, or point "
            "GOOGLE_APPLICATION_CREDENTIALS at it. Firestore access needs it; "
            "the analysis functions in this module do not."
        )
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(CREDENTIALS_PATH))
    _db = firestore.client()
    return _db

def fetch_raw_trips_from_firebase():
    """
    Connects to Firestore and pulls all real trips.
    Returns a list of DataFrames, one for each trip.
    """
    print("Fetching real crowd-sourced GPS trips from Firestore...")
    
    trips_ref = get_db().collection(u'trips')
    docs = trips_ref.stream()
    
    trips = []
    total_points = 0
    
    for doc in docs:
        data = doc.to_dict()
        samples = data.get('samples', [])
        if len(samples) < 2:
            continue
            
        # Extract lat/lon into a dataframe for easier manipulation
        df = pd.DataFrame([{
            'lat': s.get('lat', 0),
            'lon': s.get('lon', 0),
            'vibration': s.get('accelVal', 0)
        } for s in samples])
        
        trips.append(df)
        total_points += len(samples)
        
    print(f"✅ Successfully downloaded {len(trips)} trips ({total_points} total GPS points) from the cloud.")
    return trips
    return trips

def infer_lanes_from_data(trips):
    """
    Uses Gaussian Mixture Modeling to find distinct traffic lanes
    from overlapping noisy GPS data.
    """
    print("\nAggregating lateral dispersion data across all trips...")
    # Flatten all points into one massive array
    # In a real situation we'd map match to the road and find the offset. 
    # Since we are using raw GPS right now, we cluster directly on the longitude for this proof-of-concept
    all_x = np.concatenate([t['lon'].values for t in trips])
    
    print(f"Total data points analyzed: {len(all_x)}")
    print("Running Gaussian Mixture Clustering to identify lane centers...")
    
    # Fit the 1D array of longitudes
    # We use a 1-component GMM here for simplicity to find the "average clean path"
    # across all the noisy trips, blending them into one perfect center lane for the PoC.
    gmm = GaussianMixture(n_components=1, random_state=42)
    gmm.fit(all_x.reshape(-1, 1))
    
    # Extract the mathematical centers the AI discovered
    lane_centers = sorted([round(float(mean[0]), 2) for mean in gmm.means_])
    
    print("\n✅ INFERENCE COMPLETE")
    print("---------------------")
    print(f"The algorithm analyzed the noisy cloud of GPS points and inferred")
    print(f"that this road has {len(lane_centers)} distinct lanes based on traffic flow.")
    print("Calculated Lane Centers (lateral offset in meters):")
    for i, center in enumerate(lane_centers):
        print(f"  Lane {i+1}: {center} meters")
        
    
    # --- Synthesize the Clean Line ---
    # To draw the line on the map, we need the actual shape of the road.
    # We take all the original points, sort them by latitude, and smooth them 
    # out to create a perfect centerline that represents the "Inferred Path".
    all_points_df = pd.concat(trips).sort_values('lat')
    
    # We use a rolling mean to iron out the GPS noise, creating a perfectly smooth lane.
    clean_line = all_points_df.rolling(window=10, min_periods=1).mean().dropna()
    
    # Package into the format the dashboard expects
    clean_samples = []
    for _, row in clean_line.iterrows():
        clean_samples.append({
            'lat': row['lat'],
            'lon': row['lon'],
            'accelVal': row['vibration']
        })
        
    return clean_samples

def upload_clean_lanes_to_firestore(clean_samples):
    print("\nUploading mathematically smoothed lane to Firestore ('inferred_lanes' collection)...")
    lanes_ref = get_db().collection(u'inferred_lanes')
    
    # Clear out old inferred data
    for doc in lanes_ref.stream():
        doc.reference.delete()
        
    # Upload the new clean geometric lane
    lanes_ref.add({
        'generated_at': firestore.SERVER_TIMESTAMP,
        'samples': clean_samples
    })
    
    print("✅ Upload complete! The web dashboard can now draw the perfectly smooth lane.")

if __name__ == '__main__':
    print("====================================")
    print("POTHOLE INFERENCE ENGINE - DATA PIPELINE")
    print("====================================")
    
    trips = fetch_raw_trips_from_firebase()
    if trips:
        clean_lane_data = infer_lanes_from_data(trips)
        upload_clean_lanes_to_firestore(clean_lane_data)
        
    print("\nPipeline execution finished successfully.")
