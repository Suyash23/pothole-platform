import { useState, useEffect } from 'react'
import axios from 'axios'
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts'
import { MapContainer, TileLayer, CircleMarker, Popup } from 'react-leaflet'
import 'leaflet/dist/leaflet.css'
import './App.css'

const API_BASE = 'http://localhost:8000'

function App() {
  const [scenarios, setScenarios] = useState([])
  const [selectedScenario, setSelectedScenario] = useState('')
  const [loading, setLoading] = useState(false)
  const [traceData, setTraceData] = useState(null)
  const [metrics, setMetrics] = useState(null)

  useEffect(() => {
    axios.get(`${API_BASE}/scenarios`).then(res => {
      setScenarios(res.data.scenarios)
      if (res.data.scenarios.length > 0) {
        setSelectedScenario(res.data.scenarios[0].id)
      }
    })
  }, [])

  const runSimulation = async () => {
    if (!selectedScenario) return
    setLoading(true)
    try {
      const res = await axios.post(`${API_BASE}/simulate/${selectedScenario}`)
      setMetrics(res.data.metrics)
      
      const dataRes = await axios.get(`${API_BASE}/data/${selectedScenario}`)
      setTraceData(dataRes.data)
    } catch (e) {
      console.error(e)
    }
    setLoading(false)
  }

  // Subsample IMU for chart to prevent lag (e.g. take every 5th point)
  const getChartData = () => {
    if (!traceData || !traceData.imu) return []
    const data = []
    const { ax, ay, az } = traceData.imu
    for (let i = 0; i < az.length; i += 5) {
      data.push({
        time: (i / 100).toFixed(2),
        az: az[i],
        ay: ay[i]
      })
    }
    return data
  }

  return (
    <div className="min-h-screen p-8 bg-gray-900 text-gray-100 font-sans">
      <header className="mb-8 flex justify-between items-end border-b border-gray-700 pb-4">
        <div>
          <h1 className="text-4xl font-extrabold text-transparent bg-clip-text bg-gradient-to-r from-blue-400 to-purple-500">
            Synthetic Sensor Dashboard
          </h1>
          <p className="text-gray-400 mt-2">Physically grounded simulation engine for Pothole Finder</p>
        </div>
        
        <div className="flex items-center space-x-4">
          <select 
            className="bg-gray-800 border border-gray-600 text-white p-2 rounded focus:outline-none focus:ring-2 focus:ring-purple-500"
            value={selectedScenario}
            onChange={e => setSelectedScenario(e.target.value)}
          >
            {scenarios.map(s => (
              <option key={s.id} value={s.id}>{s.id}</option>
            ))}
          </select>
          <button 
            onClick={runSimulation}
            disabled={loading}
            className="bg-purple-600 hover:bg-purple-700 px-6 py-2 rounded font-bold shadow-lg shadow-purple-900/50 transition transform hover:scale-105 active:scale-95 disabled:opacity-50"
          >
            {loading ? 'Simulating...' : 'Run Scenario'}
          </button>
        </div>
      </header>

      {metrics && (
        <div className="grid grid-cols-4 gap-4 mb-8">
          <div className="bg-gray-800/50 backdrop-blur p-4 rounded-xl border border-gray-700">
            <h3 className="text-gray-400 text-sm font-semibold tracking-wider uppercase">Precision</h3>
            <p className="text-3xl font-bold text-green-400">{(metrics.precision * 100).toFixed(1)}%</p>
          </div>
          <div className="bg-gray-800/50 backdrop-blur p-4 rounded-xl border border-gray-700">
            <h3 className="text-gray-400 text-sm font-semibold tracking-wider uppercase">Recall</h3>
            <p className="text-3xl font-bold text-blue-400">{(metrics.recall * 100).toFixed(1)}%</p>
          </div>
          <div className="bg-gray-800/50 backdrop-blur p-4 rounded-xl border border-gray-700">
            <h3 className="text-gray-400 text-sm font-semibold tracking-wider uppercase">False Positives</h3>
            <p className="text-3xl font-bold text-red-400">{metrics.false_positives}</p>
          </div>
          <div className="bg-gray-800/50 backdrop-blur p-4 rounded-xl border border-gray-700">
            <h3 className="text-gray-400 text-sm font-semibold tracking-wider uppercase">Missed Events</h3>
            <p className="text-3xl font-bold text-yellow-400">{metrics.missed_events}</p>
          </div>
        </div>
      )}

      {traceData && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
          <div className="bg-gray-800/30 p-6 rounded-2xl border border-gray-700 shadow-2xl">
            <h2 className="text-xl font-bold mb-4 flex items-center">
              <span className="w-2 h-2 rounded-full bg-blue-500 mr-2"></span>
              IMU Sensor Trace (100Hz Subsampled)
            </h2>
            <div className="h-96">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={getChartData()}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                  <XAxis dataKey="time" stroke="#9CA3AF" />
                  <YAxis stroke="#9CA3AF" />
                  <Tooltip 
                    contentStyle={{ backgroundColor: '#1F2937', border: 'none', borderRadius: '8px' }}
                    itemStyle={{ color: '#E5E7EB' }}
                  />
                  <Legend />
                  <Line type="monotone" dataKey="az" stroke="#8B5CF6" strokeWidth={2} dot={false} name="Z (Vertical) g" />
                  <Line type="monotone" dataKey="ay" stroke="#3B82F6" strokeWidth={1} dot={false} name="Y (Longitudinal) g" opacity={0.5} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>

          <div className="bg-gray-800/30 p-6 rounded-2xl border border-gray-700 shadow-2xl">
            <h2 className="text-xl font-bold mb-4 flex items-center">
              <span className="w-2 h-2 rounded-full bg-green-500 mr-2"></span>
              GPS & Ground Truth Map
            </h2>
            <div className="h-96 rounded-xl overflow-hidden border border-gray-600">
              {traceData.gps && (
                <MapContainer 
                  center={[traceData.gps.lat[0], traceData.gps.lon[0]]} 
                  zoom={17} 
                  style={{ height: '100%', width: '100%' }}
                  zoomControl={false}
                >
                  <TileLayer
                    url="https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
                    attribution='&copy; OpenStreetMap contributors'
                  />
                  {traceData.gps.lat.map((lat, i) => (
                    <CircleMarker 
                      key={`gps-${i}`}
                      center={[lat, traceData.gps.lon[i]]} 
                      radius={2} 
                      color="#3B82F6" 
                      fillOpacity={0.8} 
                    />
                  ))}
                  {traceData.ground_truth.map((gt, i) => {
                    const idx = Math.min(Math.floor(gt.timestamp), traceData.gps.lat.length - 1)
                    const lat = traceData.gps.lat[idx]
                    const lon = traceData.gps.lon[idx]
                    return (
                      <CircleMarker 
                        key={`gt-${i}`}
                        center={[lat, lon]} 
                        radius={6} 
                        color={gt.type === 'pothole' ? '#EF4444' : '#F59E0B'}
                        fillOpacity={1}
                      >
                        <Popup>
                          <div className="text-gray-900 font-bold">
                            {gt.type.toUpperCase()} <br/>
                            {gt.type === 'pothole' ? `Depth: ${gt.depth_cm}cm` : ''}
                          </div>
                        </Popup>
                      </CircleMarker>
                    )
                  })}
                </MapContainer>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export default App
