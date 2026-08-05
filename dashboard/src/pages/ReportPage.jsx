import React from 'react';

const ReportPage = () => {
  return (
    <div className="main-content" style={{ padding: '32px', display: 'flex', flexDirection: 'column', gap: '16px' }}>
      <h1>City Report</h1>
      <p>This view will show PDF-ready aggregated statistics for a specific city.</p>
    </div>
  );
};

export default ReportPage;
