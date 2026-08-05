import React, { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { PanelLeftClose, PanelLeftOpen, Filter, ChevronDown, ChevronUp } from 'lucide-react';
import './LeftFilterPanel.css';

const LeftFilterPanel = ({ isCollapsed, setIsCollapsed }) => {
  const [searchParams, setSearchParams] = useSearchParams();

  // Read current filters directly from URL query parameters (stateless source of truth)
  const filters = {
    type: searchParams.getAll('type').length ? searchParams.getAll('type') : ['Potholes', 'Speed bumps', 'Manholes', 'Rough patches'],
    severity: searchParams.getAll('sev').length ? searchParams.getAll('sev') : ['Mild', 'Moderate', 'Severe'],
    confidence: parseInt(searchParams.get('conf') || '60', 10),
    reports: parseInt(searchParams.get('rep') || '3', 10),
    vehicles: searchParams.getAll('veh').length ? searchParams.getAll('veh') : ['Tesla Model Y', 'Lucid Gravity'],
    mounts: searchParams.getAll('mount').length ? searchParams.getAll('mount') : ['Stiff Mount', 'Wobbly Mount', 'Cup Holder (No Mount)'],
    scenarios: searchParams.getAll('scenario').length ? searchParams.getAll('scenario') : ['Normal Drive', 'Sudden Braking', 'Device Tapping'],
    startDate: searchParams.get('start') || '',
    endDate: searchParams.get('end') || ''
  };

  // Track which sections are expanded
  const [expandedSections, setExpandedSections] = useState({
    type: true,
    severity: true,
    confidence: true,
    reports: false,
    vehicles: false,
    mounts: false,
    scenarios: false,
    date: true
  });

  const toggleSection = (section) => {
    setExpandedSections(prev => ({ ...prev, [section]: !prev[section] }));
  };

  // Safe parameters updater
  const handleCheckboxChange = (category, value) => {
    const current = filters[
      category === 'severity' ? 'severity'
      : category === 'vehicles' ? 'vehicles'
      : category === 'mounts' ? 'mounts'
      : category === 'scenarios' ? 'scenarios'
      : 'type'
    ];
    const updated = current.includes(value) 
      ? current.filter(item => item !== value)
      : [...current, value];

    const paramKey = 
      category === 'severity' ? 'sev'
      : category === 'vehicles' ? 'veh'
      : category === 'mounts' ? 'mount'
      : category === 'scenarios' ? 'scenario'
      : 'type';
    
    const params = new URLSearchParams(window.location.search);
    params.delete(paramKey);
    updated.forEach(val => params.append(paramKey, val));
    setSearchParams(params, { replace: true });
  };

  const handleRangeChange = (paramKey, value) => {
    const params = new URLSearchParams(window.location.search);
    if (value === '') {
      params.delete(paramKey);
    } else {
      params.set(paramKey, value);
    }
    setSearchParams(params, { replace: true });
  };

  const resetFilters = () => {
    if (window.confirm("Are you sure you want to reset all filters?")) {
      const params = new URLSearchParams(window.location.search);
      params.delete('type');
      params.delete('sev');
      params.delete('conf');
      params.delete('rep');
      params.delete('veh');
      params.delete('mount');
      params.delete('scenario');
      params.delete('start');
      params.delete('end');
      setSearchParams(params, { replace: true });
    }
  };

  return (
    <aside className={`left-filter-panel ${isCollapsed ? 'collapsed' : ''}`}>
      <div className="panel-header">
        {!isCollapsed && <h2>Filters</h2>}
        <button 
          className="icon-btn collapse-btn"
          onClick={() => setIsCollapsed(!isCollapsed)}
          aria-label={isCollapsed ? "Expand filters" : "Collapse filters"}
        >
          {isCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
        </button>
      </div>

      <div className="panel-content">
        {isCollapsed ? (
          <div className="collapsed-icons">
            <Filter size={20} className="filter-icon-placeholder" />
            <div className="active-filter-indicator">{filters.type.length}</div>
          </div>
        ) : (
          <div className="filters-container">
            {/* Defect Type */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('type')}>
                <h3>Defect Type</h3>
                {expandedSections.type ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.type && (
                <div className="section-body">
                  {['Potholes', 'Speed bumps', 'Manholes', 'Rough patches', 'Unverified'].map(t => (
                    <label key={t} className="checkbox-label">
                      <input 
                        type="checkbox" 
                        checked={filters.type.includes(t)}
                        onChange={() => handleCheckboxChange('type', t)}
                      />
                      <span>{t}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>

            {/* Severity */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('severity')}>
                <h3>Severity</h3>
                {expandedSections.severity ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.severity && (
                <div className="section-body">
                  {['Mild', 'Moderate', 'Severe'].map(s => (
                    <label key={s} className="checkbox-label">
                      <input 
                        type="checkbox" 
                        checked={filters.severity.includes(s)}
                        onChange={() => handleCheckboxChange('severity', s)}
                      />
                      <span>{s}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>

            {/* Confidence */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('confidence')}>
                <h3>Min Confidence: {filters.confidence}%</h3>
                {expandedSections.confidence ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.confidence && (
                <div className="section-body">
                  <input 
                    type="range" 
                    min="0" max="100" 
                    value={filters.confidence}
                    onChange={(e) => handleRangeChange('conf', e.target.value)}
                    className="range-slider"
                    aria-label="Minimum confidence slider"
                  />
                </div>
              )}
            </div>

            {/* Reports Count */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('reports')}>
                <h3>Min Reports: {filters.reports}</h3>
                {expandedSections.reports ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.reports && (
                <div className="section-body">
                  <input 
                    type="range" 
                    min="1" max="50" 
                    value={filters.reports}
                    onChange={(e) => handleRangeChange('rep', e.target.value)}
                    className="range-slider"
                    aria-label="Minimum reports slider"
                  />
                </div>
              )}
            </div>
            
            {/* Vehicles */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('vehicles')}>
                <h3>Vehicle Models</h3>
                {expandedSections.vehicles ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.vehicles && (
                <div className="section-body">
                  {['Tesla Model Y', 'Lucid Gravity'].map(v => (
                    <label key={v} className="checkbox-label">
                      <input 
                        type="checkbox" 
                        checked={filters.vehicles.includes(v)}
                        onChange={() => handleCheckboxChange('vehicles', v)}
                      />
                      <span>{v}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>

            {/* Phone Mounts */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('mounts')}>
                <h3>Phone Mount Type</h3>
                {expandedSections.mounts ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.mounts && (
                <div className="section-body">
                  {['Stiff Mount', 'Wobbly Mount', 'Cup Holder (No Mount)'].map(m => (
                    <label key={m} className="checkbox-label">
                      <input 
                        type="checkbox" 
                        checked={filters.mounts.includes(m)}
                        onChange={() => handleCheckboxChange('mounts', m)}
                      />
                      <span>{m}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>

            {/* Scenarios */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('scenarios')}>
                <h3>Drive Scenarios</h3>
                {expandedSections.scenarios ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.scenarios && (
                <div className="section-body">
                  {['Normal Drive', 'Sudden Braking', 'Device Tapping'].map(s => (
                    <label key={s} className="checkbox-label">
                      <input 
                        type="checkbox" 
                        checked={filters.scenarios.includes(s)}
                        onChange={() => handleCheckboxChange('scenarios', s)}
                      />
                      <span>{s}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>

            {/* Date Range */}
            <div className="filter-section">
              <button className="section-header" onClick={() => toggleSection('date')}>
                <h3>Date Range</h3>
                {expandedSections.date ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              </button>
              {expandedSections.date && (
                <div className="section-body date-inputs">
                  <div className="date-input-group">
                    <label htmlFor="start-date">Start Date</label>
                    <input 
                      id="start-date"
                      type="date" 
                      value={filters.startDate}
                      onChange={(e) => handleRangeChange('start', e.target.value)}
                      className="date-picker"
                    />
                  </div>
                  <div className="date-input-group">
                    <label htmlFor="end-date">End Date</label>
                    <input 
                      id="end-date"
                      type="date" 
                      value={filters.endDate}
                      onChange={(e) => handleRangeChange('end', e.target.value)}
                      className="date-picker"
                    />
                  </div>
                </div>
              )}
            </div>

          </div>
        )}
      </div>

      {!isCollapsed && (
        <div className="panel-footer">
          <button className="reset-btn" onClick={resetFilters}>Reset all filters</button>
        </div>
      )}
    </aside>
  );
};

export default LeftFilterPanel;
