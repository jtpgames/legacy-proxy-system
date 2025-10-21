#!/bin/bash

# Script to search for request-id across log files in structured order
# Usage: ./search_request_id.sh <request-id> <log-directory-path>

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <request-id> <log-directory-path>"
    echo "Example: $0 12345 ../Automations/Baseline_Experiment/2025-10-17_16-06-18/without_fault_injector"
    exit 1
fi

REQUEST_ID="$1"
LOG_DIR="$2"

# Check if directory exists
if [ ! -d "$LOG_DIR" ]; then
    echo "Error: Directory '$LOG_DIR' does not exist"
    exit 1
fi

echo "Searching for request-id: $REQUEST_ID in $LOG_DIR"
echo "=================================================="

# Function to search in files matching a pattern
search_in_files() {
    local pattern="$1"
    local description="$2"
    local files
    
    # Find files matching the pattern
    files=$(find "$LOG_DIR" -name "$pattern" -type f 2>/dev/null | sort)
    
    if [ -n "$files" ]; then
        echo
        echo "--- $description ---"
        for file in $files; do
            if grep -l "$REQUEST_ID" "$file" 2>/dev/null; then
                echo "Found in: $(basename "$file")"
                grep --color=always -n "$REQUEST_ID" "$file" 2>/dev/null || true
                echo
            fi
        done
    fi
}

# Search in order: worker_log, ars-comp-1, proxy1, proxy2, ars-comp-2, proxy, gs_simulation_log
search_in_files "worker_log*" "Load Tester Logs (worker_log)"
search_in_files "ars-comp-1*" "ARS Component 1 Logs"
search_in_files "proxy1*" "Proxy 1 Logs (HTTP-to-MQTT)"
search_in_files "proxy2*" "Proxy 2 Logs (MQTT-to-HTTP)"
search_in_files "ars-comp-2*" "ARS Component 2 Logs"
search_in_files "gs_simulation*" "GS Simulation Logs"

# Also search for any other logs that might contain the request-id
echo
echo "--- Other Log Files ---"
other_files=$(find "$LOG_DIR" -name "*.log" -type f ! -name "worker_log*" ! -name "ars-comp-1*" ! -name "ars-comp-2*" ! -name "proxy1*" ! -name "proxy2*" ! -name "gs_simulation*" 2>/dev/null | sort)

if [ -n "$other_files" ]; then
    for file in $other_files; do
        if grep -l "$REQUEST_ID" "$file" 2>/dev/null; then
            echo "Found in: $(basename "$file")"
            grep --color=always -n "$REQUEST_ID" "$file" 2>/dev/null || true
            echo
        fi
    done
else
    echo "No other log files found."
fi

echo "=================================================="
echo "Search completed for request-id: $REQUEST_ID"