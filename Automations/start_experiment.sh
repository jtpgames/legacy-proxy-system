#!/bin/bash

set -e
set -o pipefail

function activate_venv_in_current_dir {
  # Check if the "venv" folder exists
  if [ ! -d "venv" ]; then
    echo "The 'venv' folder does not exist. Exiting."
    exit 1
  fi

  # Activate the virtual environment
  source venv/bin/activate

  # Check if the virtual environment was activated successfully
  if [ $? -eq 0 ]; then
    echo "Virtual environment 'venv' activated successfully."
  else
    echo "Failed to activate the virtual environment 'venv'. Exiting."
    exit 1
  fi
}

# Function: Display usage instructions
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --clean       Delete local experiment files (results, logs, ...)"
    echo "  -v, --verbose     Enable verbose mode"
    echo "  -t, --type TYPE   Select docker-compose file type: 'legacy' or 'ng'"
    echo "                    legacy: Use docker-compose-legacy.yml"
    echo "                    ng: Use docker-compose-ng.yml"
    echo "                    (default: legacy)"
    echo "  -h, --help        Show this help message"
    exit 0
}

# Function to cleanup resources
cleanup() {
    set +e
    echo -e "\nCleaning up..."

    # Check if docker-compose.yml exists, otherwise change directory
    if [[ ! -f "docker-compose.yml" ]]; then
        echo "docker-compose.yml not found."
        
        # First check if python directory exists in current directory
        if [[ -d "python" ]]; then
            echo "Found python directory in current location. Changing to ./python..."
            cd python || { echo "Failed to change to ./python directory! Exiting."; exit 1; }
        # If not, try to go up one level to ../python
        elif [[ -d "../python" ]]; then
            echo "Changing directory to ../python..."
            cd ../python || { echo "Failed to change to ../python directory! Exiting."; exit 1; }
        else
            echo "Neither ./python nor ../python directory exists! Cannot find docker-compose.yml. Exiting."
            exit 1
        fi
    fi

    [[ "$verbose" == true ]] && echo "Stopping all containers..."
    docker-compose down --remove-orphans

    screen -S prod_workload_screen -X quit
    screen -S load_tester_screen -X quit
    echo "shutting down load tester and waiting for 10 seconds"
    sleep 10

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

docker ps >/dev/null 2>&1 || { echo "Docker is not installed or running. Please install/start Docker first."; exit 1; }

# Initialize flags
run_cleanup=false
verbose=false
compose_type="legacy"  # Default to legacy

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
        --type=*)
            compose_type="${arg#*=}"
            shift
            ;;
        --type)
            if [[ -n "$2" && "$2" != -* ]]; then
                compose_type="$2"
                shift 2
            else
                echo "Error: Argument for $1 is missing" >&2
                exit 1
            fi
            ;;
        --help)
            usage
            ;;
    esac
done

while getopts ":cvt:h" opt; do
    case "${opt}" in
        c)
            run_cleanup=true
            ;;
        v)
            verbose=true
            ;;
        t)
            compose_type="$OPTARG"
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

# move to root folder
cd ../

# Validate compose_type
if [[ "$compose_type" != "legacy" && "$compose_type" != "ng" ]]; then
    echo "Error: Invalid type '$compose_type'. Must be 'legacy' or 'ng'."
    exit 1
fi

# Select appropriate docker-compose file
if [[ "$compose_type" == "legacy" ]]; then
    compose_file="docker-compose-legacy.yml"
    echo "Starting legacy proxy system"
else
    compose_file="docker-compose-ng.yml"
    echo "Starting NG proxy system"
fi

# move to python folder
cd python

# Create a symbolic link to the selected compose file
if [[ -f "docker-compose.yml" ]]; then
    rm docker-compose.yml
fi
ln -s "$compose_file" docker-compose.yml

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

# move to locust folder
cd locust_scripts
./delete_results.sh

activate_venv_in_current_dir

echo "Launching Production Workload directly on the last ARS component"
screen -S prod_workload_screen -d -m bash -c "python executor.py locust/gen_gs_prod_workload.py -u http://localhost:8084"

echo "Launching Alarm Device workload to the first ARS component"
cmd_ad_workload='python locust-parameter-variation.py locust/gen_gs_alarm_device_workload.py -u http://localhost:8081 -m 500 -p'

cmd_ad_workload="$cmd_ad_workload &> /dev/null"

screen -S load_tester_screen -d -m bash -c "$cmd_ad_workload"

cd ../

# move to python folder
cd python
echo -e "\nServices are running in docker containers."
docker-compose ps
echo -e "\nTo view logs:"
echo "docker-compose logs -f"
echo -e "\nPress Ctrl+C to stop all services and cleanup."

cd ../
cd locust_scripts

echo "Begin polling the locust-parameter-variation.log to check if the load test was finished ('Finished performance test.')"

file_path="locust-parameter-variation.log"

# Loop until the last line contains "Finished performance test"
while true; do
  last_line=""

  # Check if the file exists
  if [[ ! -f "$file_path" ]]; then
    echo "Error: File '$file_path' does not exist."
  else
    # Read the last line of the file
    last_line=$(tail -n 1 "$file_path")
  fi

  # Check if the last line contains the desired text
  if [[ "$last_line" == *"Finished performance test"* ]]; then
    echo $last_line
    break
  fi

  # Sleep for a short period to avoid busy-waiting
  sleep 10
done

echo "collect the results"

# Set the destination log folder based on the experiment type value
dst_log_folder="$compose_type"

echo "from load tester"

./extract_connection_errors.sh
#./export_sysstats.sh alarm_system.sar
#./export_sysstats.sh arc.sar

mkdir -p "$dst_log_folder"
mv -v *.log "$dst_log_folder/"
mv -v *.out "$dst_log_folder/"
#mv -v *.sar "$dst_log_folder/"
#mv -v *.svg "$dst_log_folder/"

echo "from Simulator"
cd ../Simulators

# Create the destination folder and move the log file
mkdir -p "$dst_log_folder" && mv -v ars_simulation.log "$dst_log_folder/gs_simulation.log"

# move back to root folder
cd ../

# Select appropriate docker-compose file
if [[ "$compose_type" == "legacy" ]]; then
    target_folder_for_logs="Baseline_Experiment"
else
    target_folder_for_logs="NG_Experiment"
fi

echo "move to locust folder and clean old results"
cd locust_scripts
./delete_results.sh
cd ../

echo "Moving all log files to Automations/$target_folder_for_logs ..."

mkdir -pv "Automations/$target_folder_for_logs/LoadTester_Logs"
mv -v "locust_scripts/$dst_log_folder/"* "Automations/$target_folder_for_logs/LoadTester_Logs/"

mkdir -pv "Automations/$target_folder_for_logs/Simulator_Logs"
mv -v "Simulators/$dst_log_folder/"* "Automations/$target_folder_for_logs/Simulator_Logs"

echo "Wait indefinitely until Ctrl+C"
while true; do
    sleep 1
done
