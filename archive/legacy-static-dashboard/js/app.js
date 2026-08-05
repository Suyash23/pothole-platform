// Import Firebase Modular SDK
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.9.0/firebase-app.js";
import { getFirestore, collection, getDocs } from "https://www.gstatic.com/firebasejs/10.9.0/firebase-firestore.js";

// Firebase configuration from firebase_options.dart
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

// Global Variables
let map;
let allPolylines = [];
let lastKnownCenter = [37.773972, -122.431297];

// Initialize Map
function initMap() {
    map = L.map('map', {
        zoomControl: false // Move zoom control
    }).setView(lastKnownCenter, 13);

    L.control.zoom({
        position: 'bottomright'
    }).addTo(map);

    // Dark-mode OSM tiles
    L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>',
        subdomains: 'abcd',
        maxZoom: 20
    }).addTo(map);
}

// Fetch Data from Firestore
async function fetchTrips() {
    const loadingState = document.getElementById('loading');

    try {
        const querySnapshot = await getDocs(collection(db, "inferred_lanes"));
        const trips = [];
        let totalPoints = 0;

        querySnapshot.forEach((doc) => {
            const data = doc.data();
            if (data.samples && data.samples.length > 0) {
                trips.push(data.samples);
                totalPoints += data.samples.length;
            }
        });

        // Update Stats UI
        document.getElementById('total-trips').innerText = trips.length;
        document.getElementById('total-points').innerText = totalPoints.toLocaleString();

        drawTrips(trips);
    } catch (error) {
        console.error("Error fetching trips:", error);
        alert("Failed to fetch data from database.");
    } finally {
        loadingState.classList.add('hidden');
    }
}

// Color Mapping Logic (matches Flutter app dynamic coloring)
function getColor(colorStr) {
    if (colorStr === 'red') return '#ef4444'; // Red Accent
    if (colorStr === 'yellow') return '#f59e0b'; // Amber
    return '#10b981'; // Green
}

function processDynamicColors(samples) {
    if (samples.length === 0) return samples;

    // Check if any sample has accelVal > 0, otherwise fallback to stored color
    const useDynamic = samples.some(s => s.accelVal !== undefined && s.accelVal > 0);
    if (!useDynamic) return samples;

    const sortedVals = samples.map(s => s.accelVal || 0).sort((a, b) => a - b);
    let p50 = sortedVals[Math.floor(sortedVals.length * 0.5)];
    let p90 = sortedVals[Math.floor(sortedVals.length * 0.9)];

    if (p90 === p50) p90 = p50 + 0.001;

    return samples.map(s => {
        const val = s.accelVal || 0;
        let c = 'green';
        if (val >= p90) c = 'red';
        else if (val >= p50) c = 'yellow';

        return { ...s, dynamicColor: c };
    });
}

// Draw Polylines on Map
function drawTrips(trips) {
    let bounds = [];

    trips.forEach(samples => {
        if (samples.length < 2) return;

        const coloredSamples = processDynamicColors(samples);
        let currentPoints = [];
        let currentColor = coloredSamples[0].dynamicColor || coloredSamples[0].color;

        for (let i = 0; i < coloredSamples.length; i++) {
            const s = coloredSamples[i];
            const pointColor = s.dynamicColor || s.color;
            const latlng = [s.lat, s.lon];

            if (pointColor !== currentColor && currentPoints.length >= 1) {
                // Add bridging point to connect lines seamlessly
                currentPoints.push(latlng);

                const pl = L.polyline(currentPoints, {
                    color: getColor(currentColor),
                    weight: 5,
                    opacity: 0.8,
                    lineJoin: 'round'
                }).addTo(map);

                allPolylines.push(pl);
                bounds = bounds.concat(currentPoints);

                currentPoints = [latlng];
                currentColor = pointColor;
            } else {
                currentPoints.push(latlng);
            }
        }

        if (currentPoints.length >= 2) {
            const pl = L.polyline(currentPoints, {
                color: getColor(currentColor),
                weight: 5,
                opacity: 0.8,
                lineJoin: 'round'
            }).addTo(map);
            allPolylines.push(pl);
            bounds = bounds.concat(currentPoints);
        }
    });

    if (bounds.length > 0) {
        lastKnownCenter = bounds[bounds.length - 1];
        map.fitBounds(L.latLngBounds(bounds), { padding: [50, 50] });
    }
}

// Event Listeners
document.getElementById('btn-recenter').addEventListener('click', () => {
    if (allPolylines.length > 0) {
        const group = new L.featureGroup(allPolylines);
        map.flyToBounds(group.getBounds(), {
            padding: [50, 50],
            duration: 1.5
        });
    } else {
        map.flyTo(lastKnownCenter, 13, { duration: 1.5 });
    }
});

// Boot
document.addEventListener('DOMContentLoaded', () => {
    initMap();
    fetchTrips();
});
