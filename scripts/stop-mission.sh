#!/bin/bash
set -euo pipefail

# stop-mission.sh — Gracefully stop the Mission Runner daemon
#
# Usage: ./scripts/stop-mission.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="${PROJECT_ROOT}/.antigravity/.mission.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "Mission Runner is not running (no PID file found)."
  exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
  echo "Mission Runner process (PID ${PID}) is not running. Cleaning up stale PID file."
  rm -f "$PID_FILE"
  exit 0
fi

echo "Stopping Mission Runner (PID ${PID})..."
kill -TERM "$PID"

# Wait for graceful shutdown (up to 30 seconds)
for i in $(seq 1 30); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "✅ Mission Runner stopped."
    rm -f "$PID_FILE"
    exit 0
  fi
  sleep 1
done

# Force kill if still running
echo "Warning: Graceful shutdown timed out. Force killing..."
kill -9 "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
echo "✅ Mission Runner force stopped."
