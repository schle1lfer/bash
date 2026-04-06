#!/usr/bin/env bash
# launch_apps.sh — sequentially launch N applications, track PIDs, clean up on exit.

# ---------------------------------------------------------------------------
# CONFIGURATION: list the applications to launch (add or remove as needed)
# ---------------------------------------------------------------------------
APPS=(
    "app1"
    "app2"
    "app3"
)
# ---------------------------------------------------------------------------

PIDS=()

# --- helpers ----------------------------------------------------------------

kill_existing() {
    local app="$1"
    local pids
    pids=$(pgrep -x "$app" 2>/dev/null)
    if [[ -n "$pids" ]]; then
        echo "[*] Killing existing '$app' processes: $pids"
        pkill -x "$app" 2>/dev/null
        # Wait briefly to allow processes to terminate
        sleep 0.3
        # Force-kill any survivors
        pkill -9 -x "$app" 2>/dev/null || true
    fi
}

launch_app() {
    local app="$1"
    echo "[*] Launching '$app' in the background..."
    "$app" &
    local pid=$!
    PIDS+=("$pid")
    echo "[+] '$app' started with PID $pid"
}

cleanup() {
    echo ""
    echo "[*] Shutting down — sending SIGTERM to tracked processes..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "    Terminating PID $pid"
            kill "$pid" 2>/dev/null
        fi
    done
    # Give processes a moment to exit gracefully
    sleep 0.5
    echo "[*] Sending SIGKILL to any remaining processes..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "    Force-killing PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    echo "[*] Cleanup complete."
    exit 0
}

# --- trap signals so cleanup runs on exit -----------------------------------
trap cleanup SIGINT SIGTERM EXIT

# --- main -------------------------------------------------------------------

echo "=== App Launcher ==="
echo "Applications: ${APPS[*]}"
echo ""

# Step 1: kill any pre-existing instances of every app
echo "--- Killing existing processes ---"
for app in "${APPS[@]}"; do
    kill_existing "$app"
done
echo ""

# Step 2: launch each app sequentially in the background
echo "--- Launching applications ---"
for app in "${APPS[@]}"; do
    if ! command -v "$app" &>/dev/null; then
        echo "[!] Warning: '$app' not found in PATH — skipping"
        continue
    fi
    launch_app "$app"
done
echo ""

echo "--- All applications started. PIDs: ${PIDS[*]} ---"
echo "--- Press Ctrl+C to stop all processes. ---"
echo ""

# Step 3: wait until interrupted — the EXIT trap handles cleanup
wait
