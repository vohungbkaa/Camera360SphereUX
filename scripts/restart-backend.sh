#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${CAMERA360_PORT:-8080}"

while IFS= read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  process_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$process_command" != *uvicorn* ]]; then
    echo "Refusing to kill PID $pid on port $port because it is not uvicorn: $process_command" >&2
    exit 1
  fi
  echo "Stopping old backend PID $pid on port $port"
  kill "$pid"
done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)

cd "$project_root"
if [[ ! -x .venv/bin/uvicorn ]]; then
  echo "Missing .venv. Run: python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt" >&2
  exit 1
fi

echo "Starting Camera360 backend at http://0.0.0.0:$port"
exec .venv/bin/uvicorn backend.app:app --host 0.0.0.0 --port "$port"
