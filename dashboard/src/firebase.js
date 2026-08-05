import { initializeApp } from "firebase/app";
import { getFirestore, collection, getDocs, doc, getDoc, updateDoc, deleteDoc } from "firebase/firestore";

const firebaseConfig = {
    apiKey: "AIzaSyBvM3i-F0vQKDhjWv8_B80kE2HMe8glhVs",
    authDomain: "pothole-finder-e323f.firebaseapp.com",
    projectId: "pothole-finder-e323f",
    storageBucket: "pothole-finder-e323f.firebasestorage.app",
    messagingSenderId: "325179381241",
    appId: "1:325179381241:web:648a794d7e9d7352659928",
    measurementId: "G-ZS8KVJB4PV"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const db = getFirestore(app);

export { app, db };

// Helper to fetch all inferred lanes
export async function fetchInferredLanes() {
  try {
    const qSnapshot = await getDocs(collection(db, "inferred_lanes"));
    const lanes = [];
    qSnapshot.forEach((doc) => {
      lanes.push({
        id: doc.id,
        ...doc.data()
      });
    });
    return lanes;
  } catch (error) {
    console.error("Error fetching inferred_lanes:", error);
    return [];
  }
}

// Helper to fetch all trips
export async function fetchTrips() {
  try {
    const qSnapshot = await getDocs(collection(db, "trips"));
    const trips = [];
    qSnapshot.forEach((doc) => {
      trips.push({
        id: doc.id,
        ...doc.data()
      });
    });
    return trips;
  } catch (error) {
    console.error("Error fetching trips:", error);
    return [];
  }
}

// Helper to delete an entire trip document
export async function deleteTripDocument(docId) {
  try {
    await deleteDoc(doc(db, "trips", docId));
    console.log(`Successfully deleted trip document: ${docId}`);
    return true;
  } catch (error) {
    console.error(`Error deleting trip document ${docId}:`, error);
    throw error;
  }
}

// Helper to prune a specific coordinate sample from a document's samples array
export async function pruneTelemetrySample(source, docId, sampleIndex) {
  try {
    const collectionName = source === 'trip' ? 'trips' : 'inferred_lanes';
    const docRef = doc(db, collectionName, docId);
    
    // Fetch current document state
    const docSnap = await getDoc(docRef);
    if (!docSnap.exists()) {
      throw new Error(`Document ${docId} does not exist in ${collectionName}`);
    }
    
    const data = docSnap.data();
    if (!data.samples || !Array.isArray(data.samples)) {
      throw new Error(`Document ${docId} does not have a samples array`);
    }
    
    // Remove the sample at the specified index
    const updatedSamples = [...data.samples];
    updatedSamples.splice(sampleIndex, 1);
    
    // Write back the updated samples array
    await updateDoc(docRef, {
      samples: updatedSamples
    });
    
    console.log(`Successfully pruned sample at index ${sampleIndex} from ${collectionName}/${docId}`);
    return true;
  } catch (error) {
    console.error(`Error pruning telemetry sample:`, error);
    throw error;
  }
}

