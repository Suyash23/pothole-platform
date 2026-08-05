import React, { useState } from 'react';
import { X, AlertTriangle, Share2, Compass, ShieldAlert, Award, Trash2 } from 'lucide-react';
import './RightDrawer.css';
import { pruneTelemetrySample, deleteTripDocument } from '../firebase';

const RightDrawer = ({ isOpen, setIsOpen, defect, onTelemetryPruned }) => {
  const [isPruning, setIsPruning] = useState(false);

  if (!isOpen || !defect) return null;

  // Format shareable URL
  const handleShare = () => {
    const shareUrl = `${window.location.origin}${window.location.pathname}?lat=${defect.lat}&lng=${defect.lng}&zoom=15&defect=${defect.id}`;
    navigator.clipboard.writeText(shareUrl);
    alert("Shareable link copied to clipboard:\n" + shareUrl);
  };

  // Safe data conversion
  const confidence = defect.confidence || 85;
  const reports = defect.reports || 3;
  const severity = defect.severity || 'Mild';
  const type = defect.type || 'Pothole';
  const vehicle = defect.vehicle || 'Tesla Model Y';
  const mountType = defect.mountType || 'Stiff Mount';
  const scenario = defect.scenario || 'Normal Drive';

  // Vehicle mix mock generator for variety
  const getVehicleMix = (v) => {
    switch (v) {
      case 'Sedan': return { sedan: 60, suv: 20, truck: 10, moto: 10 };
      case 'SUV': return { sedan: 20, suv: 60, truck: 10, moto: 10 };
      case 'Truck': return { sedan: 10, suv: 20, truck: 60, moto: 10 };
      case 'Motorcycle': return { sedan: 10, suv: 10, truck: 10, moto: 70 };
      default: return { sedan: 35, suv: 35, truck: 20, moto: 10 };
    }
  };

  const mix = getVehicleMix(vehicle);

  // Firestore delete coordinate handler
  const handlePruneSample = async () => {
    const confirmDelete = window.confirm(
      `⚠️ TELEMETRY PRUNING CONFIRMATION ⚠️\n\n` +
      `This data point is flagged as a "${defect.anomalyReason || 'Off-Road Anomaly'}".\n\n` +
      `Are you sure you want to permanently delete this coordinate sample from your Firestore database (${defect.source})? This action cannot be undone.`
    );
    
    if (!confirmDelete) return;

    setIsPruning(true);
    try {
      await pruneTelemetrySample(defect.source, defect.docId, defect.sampleIndex);
      alert("✅ Sample successfully pruned from database.");
      setIsOpen(false);
      if (onTelemetryPruned) onTelemetryPruned();
    } catch (error) {
      console.error(error);
      alert("❌ Failed to prune sample. Check console for error details.");
    } finally {
      setIsPruning(false);
    }
  };

  // Firestore delete entire trip handler
  const handleDeleteWholeTrip = async () => {
    const confirmDelete = window.confirm(
      `🚨 DESTRUCTIVE ACTION WARNING 🚨\n\n` +
      `This will permanently delete the entire Trip document (ID: ${defect.docId}) containing all of its telemetry coordinates from Firestore.\n\n` +
      `Are you sure you want to proceed?`
    );

    if (!confirmDelete) return;

    setIsPruning(true);
    try {
      await deleteTripDocument(defect.docId);
      alert("✅ Entire trip document successfully deleted.");
      setIsOpen(false);
      if (onTelemetryPruned) onTelemetryPruned();
    } catch (error) {
      console.error(error);
      alert("❌ Failed to delete trip. Check console for error details.");
    } finally {
      setIsPruning(false);
    }
  };

  return (
    <aside className="right-drawer glass" aria-label="Defect detailed telemetry drawer">
      <div className="drawer-header">
        <div className="badge-row">
          <span className={`severity-badge ${defect.isAnomalous ? 'severe anomaly' : severity.toLowerCase()}`}>
            {defect.isAnomalous ? 'Anomaly' : severity}
          </span>
          <AlertTriangle size={16} className={`alert-icon ${defect.isAnomalous ? 'severe' : severity.toLowerCase()}`} />
        </div>
        <button 
          className="icon-btn close-btn" 
          onClick={() => setIsOpen(false)}
          aria-label="Close details panel"
        >
          <X size={20} />
        </button>
      </div>

      <div className="drawer-content">
        <div className="telemetry-id">RECORD ID: {defect.id}</div>

        <div className="telemetry-metadata glass">
          <div className="meta-grid">
            <div className="meta-item">
              <span className="meta-lbl">VEHICLE</span>
              <span className="meta-val" title={vehicle}>{vehicle}</span>
            </div>
            <div className="meta-item">
              <span className="meta-lbl">MOUNT TYPE</span>
              <span className="meta-val" title={mountType}>{mountType}</span>
            </div>
            <div className="meta-item">
              <span className="meta-lbl">SCENARIO</span>
              <span className="meta-val" title={scenario}>{scenario}</span>
            </div>
          </div>
        </div>

        {/* ⚠️ HIGH VISIBILITY ANOMALY ALERT BANNER ⚠️ */}
        {defect.isAnomalous && (
          <div className="anomaly-alert-banner glass">
            <AlertTriangle className="alert-icon severe animated-pulse" size={24} />
            <div className="anomaly-info">
              <h4>Erroneous Telemetry Flagged</h4>
              <p className="anomaly-desc">{defect.anomalyReason}</p>
              <p className="anomaly-help">Heuristic scanned: coordinate is off-road, in water, or represents an impossible sensor noise spike.</p>
            </div>
          </div>
        )}
        
        <h2 className="location-title">
          {defect.isAnomalous ? 'Off-Road GPS Drift' : type} detected near {defect.lat.toFixed(4)}, {defect.lng.toFixed(4)}
        </h2>
        
        <div className="confidence-section glass">
          <div className="confidence-metrics">
            <div className="confidence-score">
              <Award size={20} className={defect.isAnomalous ? 'color-error' : 'brand-teal'} />
              <span>{confidence}%</span>
            </div>
            <div className="metric-label">System Confidence</div>
          </div>
          <p className="text-meta">
            {defect.isAnomalous 
              ? "System flagged this point as highly suspicious. Data is isolated from public city statistics."
              : `Aggregated from ${reports} sensor sweep${reports > 1 ? 's' : ''} reported by various vehicle transponders.`}
          </p>
        </div>

        {/* GPS Sensor Console Widget */}
        <div className="details-section">
          <h3>GPS Telemetry</h3>
          <div className="gps-console glass">
            <div className="gps-grid">
              <div className="gps-item">
                <span className="gps-lbl">LATITUDE</span>
                <span className="gps-val">{defect.lat.toFixed(6)}° N</span>
              </div>
              <div className="gps-item">
                <span className="gps-lbl">LONGITUDE</span>
                <span className="gps-val">{defect.lng.toFixed(6)}° W</span>
              </div>
              <div className="gps-item">
                <span className="gps-lbl">ACCELERATION</span>
                <span className="gps-val">{(defect.accelVal || 0).toFixed(3)} G</span>
              </div>
              <div className="gps-item">
                <span className="gps-lbl">ELEVATION</span>
                <span className="gps-val">{(Math.abs(Math.sin(defect.lat) * 50) + 12).toFixed(1)} m</span>
              </div>
            </div>
            <div className="compass-row">
              <Compass size={22} className="compass-spin" />
              <span>BEARING: {Math.floor((defect.lat * 1000) % 360)}° (NORTH-WEST)</span>
            </div>
          </div>
        </div>

        {/* Premium Severity Distribution Chart */}
        {!defect.isAnomalous && (
          <div className="details-section">
            <h3>Vibration Spectrum (G-Force)</h3>
            <div className="chart-container glass">
              <div className="bar-chart">
                <div className="chart-bar-row">
                  <span className="bar-lbl">Mild (0-2G)</span>
                  <div className="bar-track">
                    <div className="bar-fill mild" style={{ width: severity === 'Mild' ? '85%' : '15%' }}></div>
                  </div>
                </div>
                <div className="chart-bar-row">
                  <span className="bar-lbl">Moderate (2-5G)</span>
                  <div className="bar-track">
                    <div className="bar-fill moderate" style={{ width: severity === 'Moderate' ? '90%' : '35%' }}></div>
                  </div>
                </div>
                <div className="chart-bar-row">
                  <span className="bar-lbl">Severe (5G+)</span>
                  <div className="bar-track">
                    <div className="bar-fill severe" style={{ width: severity === 'Severe' ? '95%' : '10%' }}></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Vehicle Mix */}
        {!defect.isAnomalous && (
          <div className="details-section">
            <h3>Transponder Vehicle Mix</h3>
            <div className="vehicle-mix-widget glass">
              <div className="pie-chart-container">
                <div 
                  className="conic-pie" 
                  style={{ 
                    background: `conic-gradient(
                      #4A90E2 0% ${mix.sedan}%, 
                      #F5C842 ${mix.sedan}% ${mix.sedan + mix.suv}%, 
                      #E5484D ${mix.sedan + mix.suv}% ${mix.sedan + mix.suv + mix.truck}%, 
                      #2D9596 ${mix.sedan + mix.suv + mix.truck}% 100%
                    )` 
                  }}
                >
                  <div className="pie-donut"></div>
                </div>
              </div>
              
              <div className="pie-legend">
                <div className="legend-row">
                  <div className="legend-dot" style={{ backgroundColor: '#4A90E2' }}></div>
                  <span>Sedan ({mix.sedan}%)</span>
                </div>
                <div className="legend-row">
                  <div className="legend-dot" style={{ backgroundColor: '#F5C842' }}></div>
                  <span>SUV ({mix.suv}%)</span>
                </div>
                <div className="legend-row">
                  <div className="legend-dot" style={{ backgroundColor: '#E5484D' }}></div>
                  <span>Truck ({mix.truck}%)</span>
                </div>
                <div className="legend-row">
                  <div className="legend-dot" style={{ backgroundColor: '#2D9596' }}></div>
                  <span>Motorcycle ({mix.moto}%)</span>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>

      <div className="drawer-footer">
        {defect.isAnomalous ? (
          <div className="anomaly-curation-actions">
            <button 
              className="primary-btn prune-btn" 
              onClick={handlePruneSample}
              disabled={isPruning}
              aria-label="Delete this anomalous coordinate from Firestore database"
            >
              <Trash2 size={16} />
              <span>{isPruning ? "Pruning Telemetry..." : "Prune Erroneous Coordinate"}</span>
            </button>
            {defect.source === 'trip' && (
              <button 
                className="secondary-btn delete-trip-btn" 
                onClick={handleDeleteWholeTrip}
                disabled={isPruning}
                aria-label="Delete entire trip containing this coordinate"
              >
                <Trash2 size={16} />
                <span>Delete Entire Trip Document</span>
              </button>
            )}
          </div>
        ) : (
          <button 
            className="primary-btn report-btn" 
            onClick={() => alert("Report successfully submitted to public works department!")}
          >
            <ShieldAlert size={16} />
            <span>Dispatch Work Order</span>
          </button>
        )}
        
        <div className="share-row">
          <button className="icon-btn" onClick={handleShare} aria-label="Share defect details link">
            <Share2 size={18} />
          </button>
          <span>Share detailed telemetry</span>
        </div>
      </div>
    </aside>
  );
};

export default RightDrawer;
