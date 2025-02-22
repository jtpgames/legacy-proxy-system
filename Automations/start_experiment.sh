#!/bin/bash

set -e
set -o pipefail

# Function: Display usage instructions
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --clean       Delete local experiment files (results, logs, ...)"
    echo "  -v, --verbose     Enable verbose mode"
    echo "  -h, --help        Show this help message"
    exit 0
}

# Function to cleanup resources
cleanup() {
    set +e
    echo -e "\nCleaning up..."
    [[ "$verbose" == true ]] && echo "Stopping all containers..."
    docker-compose down --remove-orphans
    [[ "$verbose" == true ]] && echo "Cleanup completed."
    
    # Only exit if no_exit parameter is not provided
    if [[ "${1}" != "no_exit" ]]; then
        exit 0
    fi
}

# Function to check if services are running
check_services_running() {
    if docker-compose ps --quiet | grep -q .; then
        echo "Services are already running."
        return 0
    fi
    return 1
}

cleanup_logs() {

    echo "Deleting logs..."
    rm -rfv "logs"
}

# Initialize flags
run_cleanup=false
verbose=false

for arg in "$@"; do
    case "$arg" in
        --clean)
            run_cleanup=true
            shift
            ;;
        --verbose)
            verbose=true
            shift
            ;;
        --help)
            usage
            ;;
    esac
done

while getopts ":cvh" opt; do
    case "${opt}" in
        c)
            run_cleanup=true
            ;;
        v)
            verbose=true
            ;;
        h)
            usage
            ;;
        \?)
            echo "Unknown option: -$OPTARG"
            exit 1
            ;;
    esac
done

# Shift past processed options
shift $((OPTIND - 1))

# build simulator
echo "Building ARS Simulator ..."
# docker buildx build -t simulator_builder -f build_simulator_dockerfile .
# docker run --rm -v "$(pwd)/../Simulators:/app" simulator_builder ./gradlew shadowJar -PmainClass=ArsKt

# move to root folder
cd ../

echo "start legacy proxy system"
cd python

[[ "$verbose" == true ]] && echo "Verbose mode enabled."
[[ "$run_cleanup" == true ]] && cleanup_logs

# Create logs directory if it doesn't exist
mkdir -p logs

# Check if services are already running
if check_services_running; then
    echo "Cleaning up existing services before starting..."
    cleanup "no_exit"
fi

# Setup trap for Ctrl+C
trap cleanup SIGINT SIGTERM

echo "Starting services with docker-compose..."
docker-compose build
docker-compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 10

# move to root folder
cd ..

set +e

echo "Sending test message..."
curl -X POST -H "Content-Type: application/json" -H "Request-Id: 42" \
    -d '{"id": "070010", "body": "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"}' \
    http://localhost:8081/ID_REQ_KC_STORE7D3BPACKET

cd Automations
echo -e "\nServices are running in docker containers."
docker-compose ps
echo -e "\nTo view logs:"
echo "docker-compose logs -f"
echo -e "\nPress Ctrl+C to stop all services and cleanup."

# Wait indefinitely until Ctrl+C
while true; do
    sleep 1
done
