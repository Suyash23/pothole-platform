#!/bin/bash

echo "==========================================="
echo " Starting Pothole Simulator & Web Dashboard"
echo "==========================================="

# Start backend
echo "Starting FastAPI Backend on port 8000..."
source venv/bin/activate
uvicorn simulator.api:app --port 8000 &
BACKEND_PID=$!

# Start frontend
echo "Starting React Frontend..."
cd simulator-ui
npm run dev &
FRONTEND_PID=$!

echo "Dashboard running! Open your browser (usually http://localhost:5173)"
echo "Press Ctrl+C to stop everything."

# Wait for user interrupt
trap "kill $BACKEND_PID $FRONTEND_PID" EXIT
wait
