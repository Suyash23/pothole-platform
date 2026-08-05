import React from 'react';
import { Download, FileJson } from 'lucide-react';
import './TableView.css';
import { pointsToGeoJSON } from '../utils/dataProcessor';

const TableView = ({ onDefectClick, points = [] }) => {

  const handleExportCSV = () => {
    if (points.length === 0) return alert("No data to export");

    const headers = ['ID', 'Type', 'Severity', 'Confidence', 'Reports', 'Latitude', 'Longitude', 'Vehicle Model', 'Mount Type', 'Scenario', 'Date', 'Source'];
    const rows = points.map(pt => [
      pt.id,
      pt.type,
      pt.severity,
      `${pt.confidence}%`,
      pt.reports,
      pt.lat,
      pt.lng,
      pt.vehicle,
      pt.mountType || 'Stiff Mount',
      pt.scenario || 'Normal Drive',
      pt.date,
      pt.source
    ]);

    const csvContent = "data:text/csv;charset=utf-8," 
      + [headers.join(','), ...rows.map(e => e.map(val => `"${val}"`).join(','))].join('\n');
    
    const encodedUri = encodeURI(csvContent);
    const link = document.createElement("a");
    link.setAttribute("href", encodedUri);
    link.setAttribute("download", `potholes_export_${new Date().toISOString().split('T')[0]}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  const handleExportGeoJSON = () => {
    if (points.length === 0) return alert("No data to export");

    const geojson = pointsToGeoJSON(points);
    const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(geojson, null, 2));
    const downloadAnchor = document.createElement('a');
    downloadAnchor.setAttribute("href", dataStr);
    downloadAnchor.setAttribute("download", `potholes_export_${new Date().toISOString().split('T')[0]}.geojson`);
    document.body.appendChild(downloadAnchor);
    downloadAnchor.click();
    document.body.removeChild(downloadAnchor);
  };

  return (
    <div className="table-view-container">
      <div className="table-header-actions glass">
        <div className="header-info">
          <h2>Defect Ledger</h2>
          <p className="text-meta">Showing {points.length.toLocaleString()} verified road anomalies</p>
        </div>
        <div className="export-actions">
          <button className="glass-btn" onClick={handleExportCSV} aria-label="Export defect ledger to CSV">
            <Download size={16} /> CSV
          </button>
          <button className="glass-btn" onClick={handleExportGeoJSON} aria-label="Export defect ledger as GeoJSON vector data">
            <FileJson size={16} /> GeoJSON
          </button>
        </div>
      </div>
      
      <div className="table-wrapper">
        {points.length === 0 ? (
          <div className="table-empty-state">
            <p>No defects match the selected filters.</p>
          </div>
        ) : (
          <table className="defect-table" aria-label="Road defects data listing">
            <thead>
              <tr>
                <th scope="col">ID</th>
                <th scope="col">Type</th>
                <th scope="col">Severity</th>
                <th scope="col">Confidence</th>
                <th scope="col">Reports</th>
                <th scope="col">Coordinates</th>
                <th scope="col">Vehicle Model</th>
                <th scope="col">Mount Type</th>
                <th scope="col">Scenario</th>
                <th scope="col">Last Updated</th>
                <th scope="col">Action</th>
              </tr>
            </thead>
            <tbody>
              {points.map((row) => (
                <tr key={row.id}>
                  <td>{row.id}</td>
                  <td>{row.type}</td>
                  <td>
                    <span className={`severity-cell ${row.severity.toLowerCase()}`}>
                      {row.severity}
                    </span>
                  </td>
                  <td>{row.confidence}%</td>
                  <td>{row.reports}</td>
                  <td>{row.lat.toFixed(4)}, {row.lng.toFixed(4)}</td>
                  <td>{row.vehicle}</td>
                  <td>{row.mountType || 'Stiff Mount'}</td>
                  <td>{row.scenario || 'Normal Drive'}</td>
                  <td>{row.date}</td>
                  <td>
                    <button 
                      className="text-btn" 
                      onClick={() => onDefectClick(row)}
                      aria-label={`View detailed telemetry for ${row.id}`}
                    >
                      Details
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
};

export default TableView;
