import React, { useState, useEffect, useRef } from 'react';
import Map, { NavigationControl, GeolocateControl, Source, Layer } from 'react-map-gl/maplibre';
import { useSearchParams } from 'react-router-dom';
import 'maplibre-gl/dist/maplibre-gl.css';
import { Layers } from 'lucide-react';
import './MapArea.css';
import { pointsToGeoJSON } from '../utils/dataProcessor';

const MapArea = ({ onDefectClick, isLeftPanelCollapsed, points = [], tripSegments = [] }) => {
  const mapRef = useRef();
  const [searchParams, setSearchParams] = useSearchParams();
  
  // URL Viewport Sync State
  const [viewState, setViewState] = useState(() => {
    const lat = parseFloat(searchParams.get('lat'));
    const lng = parseFloat(searchParams.get('lng'));
    const zoom = parseFloat(searchParams.get('zoom'));
    
    return {
      longitude: lng || -122.4194, // Default to San Francisco
      latitude: lat || 37.7749,
      zoom: zoom || 12
    };
  });

  const [layersOpen, setLayersOpen] = useState(false);
  
  // Track Layer Visibilities
  const [activeLayers, setActiveLayers] = useState({
    heatmap: true,
    defects: true,
    trips: true
  });

  // Time Range Preset
  const [timePreset, setTimePreset] = useState(() => {
    return searchParams.get('preset') || '30days';
  });

  const timePresets = [
    { id: '7days', label: '7 days' },
    { id: '30days', label: '30 days' },
    { id: '90days', label: '90 days' },
    { id: '1year', label: '1 year' },
    { id: 'all', label: 'All time' }
  ];

  // 1. Sync viewState changes to URL search params (debounced)
  useEffect(() => {
    const handler = setTimeout(() => {
      const params = new URLSearchParams(window.location.search);
      params.set('lat', viewState.latitude.toFixed(4));
      params.set('lng', viewState.longitude.toFixed(4));
      params.set('zoom', viewState.zoom.toFixed(2));
      params.set('preset', timePreset);
      setSearchParams(params, { replace: true });
    }, 300);

    return () => clearTimeout(handler);
  }, [viewState.latitude, viewState.longitude, viewState.zoom, timePreset]);

  // 2. Animate flyTo when coordinates shift from TopBar search/city selector
  useEffect(() => {
    const urlLat = parseFloat(searchParams.get('lat'));
    const urlLng = parseFloat(searchParams.get('lng'));
    const urlZoom = parseFloat(searchParams.get('zoom'));

    if (urlLat && urlLng) {
      const latDiff = Math.abs(viewState.latitude - urlLat);
      const lngDiff = Math.abs(viewState.longitude - urlLng);
      
      // Only fly if coordinates are significantly different (prevents loop while panning)
      if (latDiff > 0.0002 || lngDiff > 0.0002) {
        setViewState(prev => ({
          ...prev,
          latitude: urlLat,
          longitude: urlLng,
          zoom: urlZoom || prev.zoom
        }));

        mapRef.current?.flyTo({
          center: [urlLng, urlLat],
          zoom: urlZoom || viewState.zoom,
          duration: 1500,
          essential: true
        });
      }
    }
  }, [searchParams]);

  // 3. Fit bounds to loaded points on initial mount if URL doesn't specify lat/lng
  useEffect(() => {
    if (points.length > 0 && !searchParams.get('lat') && !searchParams.get('lng')) {
      // Calculate bounding box
      let minLat = Infinity, maxLat = -Infinity;
      let minLng = Infinity, maxLng = -Infinity;

      points.forEach(pt => {
        if (pt.lat < minLat) minLat = pt.lat;
        if (pt.lat > maxLat) maxLat = pt.lat;
        if (pt.lng < minLng) minLng = pt.lng;
        if (pt.lng > maxLng) maxLng = pt.lng;
      });

      if (minLat !== Infinity && mapRef.current) {
        mapRef.current.fitBounds(
          [minLng, minLat, maxLng, maxLat],
          { padding: 80, duration: 1500 }
        );
      }
    }
  }, [points.length === 0]); // Trigger once when points first load

  // Format GeoJSON data source
  const defectsGeoJSON = pointsToGeoJSON(points);

  // Maplibre Layer paint configurations
  const heatmapLayer = {
    id: 'defects-heatmap-layer',
    type: 'heatmap',
    paint: {
      'heatmap-weight': [
        'interpolate',
        ['linear'],
        ['get', 'accelVal'],
        0, 0,
        100, 1
      ],
      'heatmap-intensity': [
        'interpolate',
        ['linear'],
        ['zoom'],
        0, 1,
        15, 3
      ],
      'heatmap-color': [
        'interpolate',
        ['linear'],
        ['heatmap-density'],
        0, 'rgba(0,0,0,0)',
        0.2, '#4A90E2', // Mild
        0.5, '#F5C842', // Moderate
        0.8, '#E5484D'  // Severe
      ],
      'heatmap-radius': [
        'interpolate',
        ['linear'],
        ['zoom'],
        0, 3,
        15, 22
      ],
      'heatmap-opacity': [
        'interpolate',
        ['linear'],
        ['zoom'],
        14, 0.8,
        16, 0
      ]
    },
    layout: {
      visibility: activeLayers.heatmap ? 'visible' : 'none'
    }
  };

  const circleLayer = {
    id: 'defects-circle-layer',
    type: 'circle',
    paint: {
      'circle-radius': [
        'interpolate',
        ['linear'],
        ['zoom'],
        10, 4,
        15, 7,
        20, 14
      ],
      'circle-color': ['get', 'color'],
      'circle-stroke-width': 1.5,
      'circle-stroke-color': '#ffffff',
      'circle-opacity': [
        'interpolate',
        ['linear'],
        ['zoom'],
        12, 0,
        14, 0.5,
        15, 1
      ],
      'circle-stroke-opacity': [
        'interpolate',
        ['linear'],
        ['zoom'],
        13, 0,
        15, 1
      ]
    },
    layout: {
      visibility: activeLayers.defects ? 'visible' : 'none'
    }
  };

  return (
    <div className="map-area-container">
      <Map
        ref={mapRef}
        {...viewState}
        onMove={evt => setViewState(evt.viewState)}
        mapStyle="https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json"
        style={{ width: '100%', height: '100%' }}
        interactiveLayerIds={activeLayers.defects ? ['defects-circle-layer'] : []}
        onClick={(e) => {
          if (e.features && e.features.length > 0) {
            onDefectClick(e.features[0].properties);
          }
        }}
      >
        <NavigationControl position="bottom-right" style={{ marginBottom: '120px' }} />
        <GeolocateControl position="bottom-right" style={{ marginBottom: '10px' }} />

        {/* 1. Defect Point & Heatmap Source */}
        {points.length > 0 && (
          <Source type="geojson" data={defectsGeoJSON}>
            <Layer {...heatmapLayer} />
            <Layer {...circleLayer} />
          </Source>
        )}

        {/* 2. Trip Lines Source */}
        {tripSegments.length > 0 && (
          <Source type="geojson" data={{
            type: "FeatureCollection",
            features: tripSegments
          }}>
            <Layer 
              id="trips-line-layer"
              type="line"
              paint={{
                'line-color': ['get', 'color'],
                'line-width': [
                  'interpolate',
                  ['linear'],
                  ['zoom'],
                  10, 2,
                  15, 5,
                  20, 10
                ],
                'line-opacity': 0.75
              }}
              layout={{
                'line-join': 'round',
                'line-cap': 'round',
                visibility: activeLayers.trips ? 'visible' : 'none'
              }}
            />
          </Source>
        )}
      </Map>

      {/* Glassmorphic Layer Selection Overlay */}
      <div className="map-layer-toggles glass">
        <button className="icon-btn" onClick={() => setLayersOpen(!layersOpen)}>
          <Layers size={18} />
          <span>Layers</span>
        </button>
        {layersOpen && (
          <div className="layers-menu">
            <label className="checkbox-label">
              <input 
                type="checkbox" 
                checked={activeLayers.heatmap}
                onChange={(e) => setActiveLayers(prev => ({ ...prev, heatmap: e.target.checked }))} 
              /> 
              <span>Vibration Heatmap</span>
            </label>
            <label className="checkbox-label">
              <input 
                type="checkbox" 
                checked={activeLayers.defects}
                onChange={(e) => setActiveLayers(prev => ({ ...prev, defects: e.target.checked }))} 
              /> 
              <span>Individual Defects</span>
            </label>
            <label className="checkbox-label">
              <input 
                type="checkbox" 
                checked={activeLayers.trips}
                onChange={(e) => setActiveLayers(prev => ({ ...prev, trips: e.target.checked }))} 
              /> 
              <span>Trip Sensor Paths</span>
            </label>
          </div>
        )}
      </div>

      {/* Compact Timeline Range / Time Slider Overlay */}
      <div className="time-slider-container glass">
        <div className="time-slider-header">
          <div className="time-chips">
            {timePresets.map(preset => (
              <button 
                key={preset.id}
                className={`chip ${timePreset === preset.id ? 'active' : ''}`}
                onClick={() => setTimePreset(preset.id)}
              >
                {preset.label}
              </button>
            ))}
          </div>
          <div className="compare-toggle">
            <label className="checkbox-label">
              <input type="checkbox" aria-label="Compare mode" />
              <span>Compare Mode</span>
            </label>
          </div>
        </div>

        <div className="slider-track-container">
          {/* Histogram background (reflecting volume of filtered defects) */}
          <div className="histogram-bars">
            {[15, 30, 65, 45, 20, 85, 95, 75, 40, 55, 80, 45, 15, 35].map((h, i) => (
              <div 
                key={i} 
                className={`bar ${i >= 6 ? 'active' : ''}`} 
                style={{ height: `${h}%` }}
              ></div>
            ))}
          </div>
          
          <div className="slider-controls">
            <input 
              type="range" 
              min="0" max="100" 
              defaultValue="75" 
              className="time-range-input" 
              aria-label="Filter by time offset"
            />
          </div>
        </div>
      </div>
    </div>
  );
};

export default MapArea;
