import React, { useState, useEffect, useRef } from 'react';
import { Search, MapPin, Menu, User, Sun, Moon, X } from 'lucide-react';
import { Link, useSearchParams } from 'react-router-dom';
import './TopBar.css';

const TopBar = ({ toggleTheme, theme }) => {
  const [searchParams, setSearchParams] = useSearchParams();
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const [city, setCity] = useState('');
  
  // Search state
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [isSearching, setIsSearching] = useState(false);
  const [showResults, setShowResults] = useState(false);
  const searchRef = useRef();

  const cities = {
    'San Francisco': { lat: 37.7749, lng: -122.4194, zoom: 12 },
    'Los Angeles': { lat: 34.0522, lng: -118.2437, zoom: 11 },
    'New York': { lat: 40.7128, lng: -74.0060, zoom: 11 }
  };

  // Close search results dropdown on clicking outside
  useEffect(() => {
    const handleOutsideClick = (e) => {
      if (searchRef.current && !searchRef.current.contains(e.target)) {
        setShowResults(false);
      }
    };
    document.addEventListener('mousedown', handleOutsideClick);
    return () => document.removeEventListener('mousedown', handleOutsideClick);
  }, []);

  // Update selected city dropdown if URL matches a city's center (approximate)
  useEffect(() => {
    const lat = parseFloat(searchParams.get('lat'));
    const lng = parseFloat(searchParams.get('lng'));
    if (!lat || !lng) return;

    let matchedCity = '';
    for (const [cityName, coords] of Object.entries(cities)) {
      const dist = Math.abs(coords.lat - lat) + Math.abs(coords.lng - lng);
      if (dist < 0.05) {
        matchedCity = cityName;
        break;
      }
    }
    setCity(matchedCity);
  }, [searchParams]);

  // Handle Nominatim Address Search
  useEffect(() => {
    if (searchQuery.length < 3) {
      setSearchResults([]);
      return;
    }

    const delayDebounceFn = setTimeout(async () => {
      setIsSearching(true);
      try {
        const response = await fetch(
          `https://nominatim.openstreetmap.org/search?format=json&q=${encodeURIComponent(searchQuery)}&limit=5`
        );
        const data = await response.json();
        setSearchResults(data);
        setShowResults(true);
      } catch (error) {
        console.error("Nominatim search error:", error);
      } finally {
        setIsSearching(false);
      }
    }, 400);

    return () => clearTimeout(delayDebounceFn);
  }, [searchQuery]);

  const handleCityChange = (cityName) => {
    setCity(cityName);
    const coords = cities[cityName];
    if (coords) {
      const params = new URLSearchParams(window.location.search);
      params.set('lat', coords.lat.toFixed(4));
      params.set('lng', coords.lng.toFixed(4));
      params.set('zoom', coords.zoom.toFixed(2));
      setSearchParams(params);
    }
  };

  const handleResultClick = (res) => {
    const lat = parseFloat(res.lat);
    const lng = parseFloat(res.lon);
    const params = new URLSearchParams(window.location.search);
    params.set('lat', lat.toFixed(4));
    params.set('lng', lng.toFixed(4));
    params.set('zoom', '15.00'); // Zoom in for address search
    setSearchParams(params);
    setSearchQuery(res.display_name);
    setShowResults(false);
  };

  return (
    <header className="top-bar glass">
      <div className="top-bar-left">
        <Link to="/" className="logo-container" style={{textDecoration: 'none', color: 'inherit'}}>
          <div className="logo-icon"></div>
          <h1>Pothole Finder</h1>
        </Link>
      </div>

      <div className="top-bar-center">
        <div className="search-container" ref={searchRef}>
          <Search size={18} className="search-icon" />
          <input 
            type="text" 
            placeholder="Search address or intersection..." 
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            onFocus={() => setShowResults(true)}
            aria-label="Search address"
          />
          {searchQuery && (
            <button className="clear-btn" onClick={() => { setSearchQuery(''); setSearchResults([]); }} aria-label="Clear search">
              <X size={14} />
            </button>
          )}
          {showResults && searchResults.length > 0 && (
            <ul className="search-results-dropdown glass">
              {searchResults.map((res) => (
                <li key={res.place_id} onClick={() => handleResultClick(res)}>
                  <MapPin size={14} className="pin-icon" />
                  <span className="result-text">{res.display_name}</span>
                </li>
              ))}
            </ul>
          )}
          {isSearching && <div className="search-spinner"></div>}
        </div>
        
        <div className="city-selector">
          <MapPin size={18} />
          <select 
            value={city} 
            onChange={(e) => handleCityChange(e.target.value)}
            aria-label="Select city"
          >
            <option value="" disabled>Select City</option>
            {Object.keys(cities).map(cityName => (
              <option key={cityName} value={cityName}>{cityName}</option>
            ))}
          </select>
        </div>
      </div>

      <div className="top-bar-right">
        <button className="icon-btn sign-in-btn">
          <User size={18} />
          <span>Sign In</span>
        </button>
        
        <button 
          className="icon-btn theme-toggle" 
          onClick={toggleTheme}
          aria-label="Toggle theme"
        >
          {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
        </button>

        <div className="menu-container">
          <button 
            className="icon-btn hamburger-btn"
            onClick={() => setIsMenuOpen(!isMenuOpen)}
            aria-label="Menu"
          >
            <Menu size={24} />
          </button>
          
          {isMenuOpen && (
            <div className="dropdown-menu glass" onClick={() => setIsMenuOpen(false)}>
              <ul>
                <li><Link to="/">Dashboard Map</Link></li>
                <li><Link to="/report/san-francisco">City Report</Link></li>
                <li><Link to="/compare">Compare View</Link></li>
                <li><Link to="/trips">Trips Coverage</Link></li>
              </ul>
            </div>
          )}
        </div>
      </div>
    </header>
  );
};

export default TopBar;
