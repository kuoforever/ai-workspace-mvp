#!/usr/bin/env bash
set -euo pipefail
# Replace only the backend launched by this platform's isolated GitHub job.
# Local benchmark runs keep their existing service and record its dataset size.
test "${GITHUB_ACTIONS:-}" = true
platform="$1"
case "$platform" in android|ios) ;; *) exit 1 ;; esac
service_pid_file="$RUNNER_TEMP/$platform-api.pid"
if [ -f "$service_pid_file" ]; then
    old_service_pid=$(cat "$service_pid_file")
    kill "$old_service_pid"
    for attempt in {1..50}; do
        if ! kill -0 "$old_service_pid" 2>/dev/null; then break; fi
        sleep 0.2
    done
fi
AI_WORKSPACE_DATA="$RUNNER_TEMP/$platform-perf-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" \
    .venv/bin/python -m uvicorn app.api:app --host 127.0.0.1 --port 8765 \
    >"$RUNNER_TEMP/$platform-perf-api.log" 2>&1 &
printf '%s\n' "$!" >"$service_pid_file"
for attempt in {1..30}; do
    if curl --fail --silent http://127.0.0.1:8765/api/config >/dev/null; then break; fi
    sleep 1
done
curl --fail --silent http://127.0.0.1:8765/api/reviews | \
    .venv/bin/python -c 'import json,sys; assert json.load(sys.stdin) == [], "Performance backend must start empty"'
