import React, { useState, useEffect } from 'react';
import './StatusBar.css';

const StatusBar = ({ viewMode, onViewModeToggle, filteredCount = 0, totalCount = 0, lastUpdated = new Date(), onRefresh }) => {
  const [timeAgo, setTimeAgo] = useState('just now');

  useEffect(() => {
    const updateTime = () => {
      const diffMs = new Date() - new Date(lastUpdated);
      const diffSec = Math.floor(diffMs / 1000);
      
      if (diffSec < 15) {
        setTimeAgo('just now');
      } else if (diffSec < 60) {
        setTimeAgo(`${diffSec}s ago`);
      } else {
        const diffMin = Math.floor(diffSec / 60);
        setTimeAgo(`${diffMin}m ago`);
      }
    };

    updateTime();
    const interval = setInterval(updateTime, 5000); // Update every 5s
    return () => clearInterval(interval);
  }, [lastUpdated]);

  return (
    <footer className="status-bar">
      <div className="status-left">
        <span aria-live="polite">
          Showing <strong>{filteredCount.toLocaleString()}</strong> of <strong>{totalCount.toLocaleString()}</strong> defect points
        </span>
      </div>

      <div className="status-center">
        <span>Last updated {timeAgo}</span>
        <button className="text-btn refresh-btn" onClick={onRefresh} aria-label="Refresh Firestore data">
          Refresh
        </button>
      </div>

      <div className="status-right">
        <span className="attribution">© OpenStreetMap & CARTO</span>
        
        <div className="severity-legend" aria-label="Severity colors ramp">
          <span>Low</span>
          <div className="severity-ramp"></div>
          <span>Severe</span>
        </div>

        <button 
          className="text-btn view-table-btn"
          onClick={onViewModeToggle}
          aria-label={viewMode === 'map' ? 'Switch to accessible table view' : 'Switch to map view'}
        >
          {viewMode === 'map' ? 'View as table' : 'View as map'}
        </button>
      </div>
    </footer>
  );
};

export default StatusBar;
