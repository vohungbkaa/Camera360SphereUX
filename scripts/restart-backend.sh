#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${CAMERA360_PORT:-8080}"

# Identify this project's backend by executable arguments AND process cwd. The
# old server may be listening on a different port, so the port is not its ID.
backend_pids=""
while read -r pid process_command; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  [[ "$process_command" == *uvicorn* && "$process_command" == *backend.app:app* ]] || continue
  process_cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  [[ "$process_cwd" == "$project_root" ]] || continue
  backend_pids="${backend_pids}${pid}"$'\n'
done < <(ps ax -o pid=,command=)

while IFS= read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  process_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  echo "Stopping Camera360 backend PID $pid: $process_command"
  kill "$pid"
done <<< "$backend_pids"

# Wait briefly for the old sockets to close before binding the requested port.
while IFS= read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  for _ in {1..50}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Camera360 backend PID $pid did not stop; refusing to start a duplicate." >&2
    exit 1
  fi
done <<< "$backend_pids"

# The requested port may belong to an unrelated service. Never kill it.
port_pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$port_pids" ]]; then
  echo "Port $port is occupied by another process; that process was not killed:" >&2
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    ps -p "$pid" -o pid=,command= >&2 || true
  done <<< "$port_pids"
  echo "Choose another port, for example: CAMERA360_PORT=8081 ./scripts/restart-backend.sh" >&2
  exit 1
fi

cd "$project_root"
if [[ ! -x .venv/bin/uvicorn ]]; then
  echo "Missing .venv. Run: python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt" >&2
  exit 1
fi

echo "Starting Camera360 backend at http://0.0.0.0:$port"
exec "$project_root/.venv/bin/uvicorn" backend.app:app \
  --app-dir "$project_root" --host 0.0.0.0 --port "$port"
