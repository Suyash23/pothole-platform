import React, { useState, useEffect } from 'react';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import TopBar from './components/TopBar';
import Dashboard from './pages/Dashboard';
import ReportPage from './pages/ReportPage';
import ComparePage from './pages/ComparePage';
import TripsPage from './pages/TripsPage';
import './index.css';

function App() {
  const [theme, setTheme] = useState(() => {
    const savedTheme = localStorage.getItem('theme');
    if (savedTheme) return savedTheme;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  });

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('theme', theme);
  }, [theme]);

  const toggleTheme = () => {
    setTheme(prev => (prev === 'light' ? 'dark' : 'light'));
  };

  return (
    <BrowserRouter>
      <div className="app-shell">
        <TopBar toggleTheme={toggleTheme} theme={theme} />
        
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/report/:city" element={<ReportPage />} />
          <Route path="/compare" element={<ComparePage />} />
          <Route path="/trips" element={<TripsPage />} />
        </Routes>
      </div>
    </BrowserRouter>
  );
}

export default App;
