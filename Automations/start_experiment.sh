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
    echo "Usage: $0 [options] <failover|performance> [duration for failover experiment]"
    echo "Options:"
    echo "  -c, --clean       Delete local experiment files (results, logs, ...)"
    echo "  -v, --verbose     Enable verbose mode"
    echo "  -t, --type TYPE   Select docker-compose file type: 'legacy' or 'ng'"
    echo "                    legacy: Use docker-compose-legacy.yml"
    echo "                    ng: Use docker-compose-ng.yml"
    echo "                    (default: legacy)"
    echo "  --with_fault_injector  Run Fault Injector"
    echo "  --without_timestamp     Run experiment without timestamped folder. Uses --clean implicitly.)"
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
       
        cd "$root_folder"

        # First check if python directory exists in current directory
        if [[ -d "python" ]]; then
            echo "Found python directory in current location. Changing to ./python..."
            cd python || { echo "Failed to change to ./python directory! Exiting."; exit 1; }
        else
            echo "python does not directory exist! Cannot find docker-compose.yml. Exiting."
            exit 1
        fi
    fi

    # At this point, the current working directory is /python

    echo "Stopping Fault injectors and terminating screen session..."
    pgrep -f 'python inject_fault.py' | xargs kill -TERM
    sleep 1
    screen -S inject_fault_session_1 -X quit 2>/dev/null || true
    screen -S inject_fault_session_2 -X quit 2>/dev/null || true

    echo "Stopping load testers and waiting for an additional 10 seconds grace period"
    docker stop prod_workload_container ad_workload_container 2>/dev/null || true
    sleep 10
    echo "Stopping all containers..."
    docker-compose down --remove-orphans

    if [[ "${1}" != "no_exit" ]]; then
      echo "collect the results"

      echo "from legacy_proxies"
      echo "to Automations/$target_folder_for_logs ..."

      # here we are still in the python folder
      mkdir -pv "$root_folder/Automations/$target_folder_for_logs/LegacyProxy_Logs"
      mv -v "logs/"* "$root_folder/Automations/$target_folder_for_logs/LegacyProxy_Logs"

      for file in ${fault_injector_logfile_base_name}*.log; do
        mv -v "$file" "$root_folder/Automations/$target_folder_for_logs/"
      done

      # change to target log folder for docker logs
      cd "$root_folder/Automations/$target_folder_for_logs"

      echo "from locust_scripts runner"

      docker logs prod_workload_container > prod_workload_container.log 2>&1
      docker logs ad_workload_container > ad_workload_container.log 2>&1
      docker rm prod_workload_container ad_workload_container 2>/dev/null || true

      # change back to root folder
      cd "$root_folder"

      # Set the destination log folder based on the experiment type value
      dst_log_folder="experiment_logs_$experiment_type"

      echo "from load tester"
      cd locust_scripts

      # Create the destination folder
      mkdir -p "$dst_log_folder"

      # move to prod_workload logs folder
      cd locust_logs/prod_workload
      mv -v *.log "../../$dst_log_folder/"
      # move back to locust_scripts folder
      cd ../../

      # move to ad_workload logs folder
      cd locust_logs/ad_workload
      mv -v *.log "../../$dst_log_folder/"
      # move back to locust_scripts folder
      cd ../../

      cd $dst_log_folder
      bash ../extract_connection_errors.sh
      cd ../

      echo "from Simulator"
      cd "$root_folder/Simulators"

      # Create the destination folder and move the log file
      mkdir -p "$dst_log_folder" && mv -v ars_simulation.log "$dst_log_folder/gs_simulation.log"

      echo "Number of received alarm messages:"
      grep -c "200 OK:.*ID_REQ_KC_STORE.*" "$dst_log_folder/gs_simulation.log"

      # move back to root folder
      cd "$root_folder"

      echo "Moving all log files to Automations/$target_folder_for_logs ..."

      mkdir -pv "Automations/$target_folder_for_logs/LoadTester_Logs"
      mv -v "locust_scripts/$dst_log_folder/"* "Automations/$target_folder_for_logs/LoadTester_Logs/"

      mkdir -pv "Automations/$target_folder_for_logs/Simulator_Logs"
      mv -v "Simulators/$dst_log_folder/"* "Automations/$target_folder_for_logs/Simulator_Logs"

      cd "$root_folder/locust_scripts"
      activate_venv_in_current_dir
      if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
        python loadtest_plotter.py "$root_folder/Automations/$target_folder_for_logs/LoadTester_Logs/locust_log_1.log" \
          "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_proxy_1" \
          "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_target_service" \
          -o "$root_folder/Automations/$target_folder_for_logs/results_$failover_or_performance_load.pdf"

          cd "$root_folder/Automations/$target_folder_for_logs"
          echo "Determining if all requests that have been sent by the load tester have been successfully received and processed by the Simulator..."
          # Count matches in LoadTester_Logs/locust_log_1.log
          # the following regex captures the reuest-id enclosed in () from the capture group (\d+) and only for the first send to the first server (7081)
          # ignoring retries to the other servers.
          # TODO: What about resends to the first? I think I need to deduplicate using "sort -u" before "| tee"
          echo "Determining distinct request-ids..."
          count_file1=$(perl -n -e 'print "$1\n" if /\((\d+)\)\sSending to.*7081/' LoadTester_Logs/locust_log_1.log | sort -u | tee request_ids.txt | wc -l)

          echo "Count corresponding matches in Simulator_Logs/gs_simulation.log"
          count_file2=$(sed 's/$/, CMD-ENDE/' request_ids.txt | grep -Ff - Simulator_Logs/gs_simulation.log | wc -l)

          echo "Request-Ids in locust_log_1.log: $count_file1"
          echo "Matches in gs_simulation.log: $count_file2"

      else
        python loadtest_plotter.py "$root_folder/Automations/$target_folder_for_logs/LoadTester_Logs/locust-parameter-variation.log" \
          "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_proxy_1" \
          "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_target_service" \
          -o "$root_folder/Automations/$target_folder_for_logs/results_$failover_or_performance_load.pdf"

        # TODO: Validate equal numbers of sent and received requests simila to the failover test
      fi

      # to trace a request to the following:
      # 1. retrieve the request-id of the request you want to trace from the load tester logs, then
      # for fail over test
      # grep "request-id" LoadTester_Logs/locust_log_1.log LegacyProxy_Logs/ars-comp-1-1.log LegacyProxy_Logs/proxy-1.log Simulator_Logs/gs_simulation.log
      # for performance test
      # grep "request_id" LoadTester_Logs/locust_log_1.log LegacyProxy_Logs/ars-comp-1-1.log LegacyProxy_Logs/proxy1-1.log LegacyProxy_Logs/proxy2-1.log Simulator_Logs/gs_simulation.log
      # --------------------------
      # perl -n -e 'print "$1, CMD-ENDE\n" if /\((\d+)\)\sSending to/' LoadTester_Logs/locust_log_1.log | xargs -I {} grep {} Simulator_Logs/gs_simulation.log
      # --------------------------
      # # Count matches in LoadTester_Logs/locust_log_1.log
      # count_file1=$(perl -n -e 'print "$1\n" if /\((\d+)\)\sSending to/' LoadTester_Logs/locust_log_1.log | tee request_ids.txt | wc -l)
      #
      # # Count corresponding matches in Simulator_Logs/gs_simulation.log
      # count_file2=$(sed 's/$/, CMD-ENDE/' request_ids.txt | grep -Ff - Simulator_Logs/gs_simulation.log | wc -l)
      #
      # # Print counts
      # echo "Matches in file1: $count_file1"
      # echo "Matches in file2: $count_file2"

      exit 0
    fi

    echo "Cleanup completed."
    set -e
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

log() {
  if [[ "$verbose" == true ]]; then
    echo "$@"
  fi
}

docker ps >/dev/null 2>&1 || { echo "Docker is not installed or running. Please install/start Docker first."; exit 1; }

# Initialize flags
run_cleanup=false
verbose=false
experiment_type="legacy"  # Default to legacy
with_fault_injector=false
include_timestamp_to_experiment_result_folder=true

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
            experiment_type="${arg#*=}"
            shift
            ;;
        --type)
            if [[ -n "$2" && "$2" != -* ]]; then
                experiment_type="$2"
                shift 2
            else
                echo "Error: Argument for $1 is missing" >&2
                exit 1
            fi
            ;;
        --without_timestamp)
            include_timestamp_to_experiment_result_folder=false
            run_cleanup=true
            shift
            ;;
        --with_fault_injector)
            with_fault_injector=true
            shift
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
            experiment_type="$OPTARG"
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

# After options, expect the positional argument for the load type
if [[ $# -lt 1 ]]; then
  echo "Error: At least one positional argument is required" >&2
  usage
fi

failover_or_performance_load="$1"
shift

# -- Validate arguments --
# --
failover_load_type="failover"
performance_load_type="performance"
if [[ "$failover_or_performance_load" != "$failover_load_type" && "$failover_or_performance_load" != "$performance_load_type" ]]; then
    echo "Error: Invalid load type '$failover_or_performance_load'. Must be '$failover_load_type' or '$performance_load_type'."
    exit 1
fi

if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
  # Expect another positional argument for the experiment duration in minutes

  if [[ $# -ne 1 ]]; then
    echo "Error: Load Type $failover_load_type expects the duration in minutes as a second positional argument." >&2
    usage
  fi

  failover_experiment_duration_minutes="$1"
  shift
fi

if [[ "$experiment_type" != "legacy" && "$experiment_type" != "ng" ]]; then
    echo "Error: Invalid type '$experiment_type'. Must be 'legacy' or 'ng'."
    exit 1
fi
# --

echo "Starting experiment given the following args:"
echo "run_cleanup=$run_cleanup"
echo "verbose=$verbose"
echo "experiment_type=$experiment_type"
echo "with_fault_injector=$with_fault_injector"
echo "include_timestamp_to_experiment_result_folder=$include_timestamp_to_experiment_result_folder"
echo "Load Type: $failover_or_performance_load"

automations_folder=$(pwd)

# Check if current directory name is "Automations"
if [[ "$(basename "$automations_folder")" != "Automations" ]]; then
  echo "Error: Current directory is not 'Automations'. It is '"$automations_folder"'."
  echo "Please always execute the experiment from within the Automations directory."
  exit 1
fi

# move to root folder
cd ../

root_folder=$(pwd)

# Select appropriate docker-compose file
if [[ "$experiment_type" == "legacy" ]]; then
    compose_file="docker-compose-legacy.yml"
    echo "Starting legacy proxy system"
else
    compose_file="docker-compose-ng.yml"
    echo "Starting NG proxy system"
fi

# set folder for log files based on experiment_type 
if [[ "$experiment_type" == "legacy" ]]; then
    target_folder_for_logs="Baseline_Experiment"
else
    target_folder_for_logs="NG_Experiment"
fi

# get current date-time in a UNIX-safe format (e.g., 2025-06-10_14-23-45)
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

# determine fault injector subdirectory
if [[ "$with_fault_injector" == "true" ]]; then
    fault_injector_subdir="with_fault_injector"
else
    fault_injector_subdir="without_fault_injector"
fi

# compose the full path
if [[ "$include_timestamp_to_experiment_result_folder" == "true" ]]; then
  target_folder_for_logs="$target_folder_for_logs/$timestamp/$fault_injector_subdir"
else
  target_folder_for_logs="$target_folder_for_logs/$fault_injector_subdir"
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
    cd "$root_folder/python"
fi

# Setup trap for Ctrl+C
trap cleanup SIGINT SIGTERM

echo "Starting services with docker-compose..."
docker-compose build
docker-compose up -d

fault_injector_logfile_base_name="fault_injector"
fault_injector_logfile_name_target_service="${fault_injector_logfile_base_name}_target_service.log"
fault_injector_logfile_name_proxy_1="${fault_injector_logfile_base_name}_proxy_1.log"

touch $fault_injector_logfile_name_target_service
touch $fault_injector_logfile_name_proxy_1
if [[ "$with_fault_injector" == "true" ]]; then
    echo "Fault Injector starting ..."
    activate_venv_in_current_dir

    # screen -dmS inject_fault_session_1 bash -c \
    # "python inject_fault.py --target-service target-service \
    #  --fault-mode stop --duration-down 10 --duration-up 60 \
    #  > \"$fault_injector_logfile_name_target_service\" 2>&1"

    if [[ "$experiment_type" == "legacy" ]]; then
      screen -dmS inject_fault_session_2 bash -c \
        "python inject_fault.py --target-service ars-comp-1-1 --target-service proxy-1 --target-service target-service \
        --fault-mode stop_once --duration-down 10 --duration-up 20 \
        > \"$fault_injector_logfile_name_proxy_1\" 2>&1"
    else
      screen -dmS inject_fault_session_2 bash -c \
        "python inject_fault.py --target-service ars-comp-1-1 --target-service proxy1-1 --target-service proxy2-1 --target-service target-service \
        --fault-mode stop_once --duration-down 10 --duration-up 20 \
        > \"$fault_injector_logfile_name_proxy_1\" 2>&1"
    fi
    
    echo "Fault Injectors started"
else
    echo "Running without Fault Injectors"
fi

# Wait for services to be ready
echo "Waiting for services to start..."
if [[ "$experiment_type" == "legacy" ]]; then
  sleep 10
else
  sleep 15
fi

echo $(screen -ls)

# move to root folder
cd "$root_folder"

set +e

# move to locust folder
cd locust_scripts

# Get the full path of locust_scripts directory for volume mounting
LOCUST_SCRIPTS_DIR="$(pwd)"
echo "Using locust scripts directory: $LOCUST_SCRIPTS_DIR"

# Create logs directories if they do not exist
mkdir -p locust_logs/prod_workload
mkdir -p locust_logs/ad_workload

# Delete any logs remaining from the previous execution
rm -fv locust_logs/prod_workload/* 
rm -fv locust_logs/ad_workload/* 

cmd_prod_workload='python executor.py locust/gen_gs_prod_workload.py -u http://host.docker.internal:8084'
echo "Launching Production Workload directly on the last ARS component"

docker run -d \
  --name prod_workload_container \
  -v "$LOCUST_SCRIPTS_DIR/locust_logs/prod_workload:/logs" \
  -v /etc/localtime:/etc/localtime:ro \
  locust_scripts_runner:latest \
  bash -c "$cmd_prod_workload"

echo "Launching Alarm Device workload to the first ARS component"
if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
  cmd_ad_workload='python locust-parameter-variation.py locust/gen_gs_alarm_device_workload_2.py -u http://host.docker.internal:7081,http://host.docker.internal:7082,http://host.docker.internal:7083 -m 1'
else
  cmd_ad_workload='python locust-parameter-variation.py locust/gen_gs_alarm_device_workload_2.py -u http://host.docker.internal:7081,http://host.docker.internal:7082,http://host.docker.internal:7083 -m 500 -p'
fi

docker run -d \
  --name ad_workload_container \
  -v "$LOCUST_SCRIPTS_DIR/locust_logs/ad_workload:/logs" \
  -v /etc/localtime:/etc/localtime:ro \
  locust_scripts_runner:latest \
  bash -c "$cmd_ad_workload"

# move to root folder
cd "$root_folder"

# move to python folder
cd python
echo -e "\nServices are running in docker containers."
docker-compose ps
echo -e "\nTo view logs:"
echo "docker-compose logs -f"
echo -e "\nPress Ctrl+C to stop all services and cleanup."

# move to root folder
cd "$root_folder"

# move to locust_scripts folder
cd locust_scripts

if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
  echo "Experiment runs for $failover_experiment_duration_minutes minute(s)."

  duration_sec=$((failover_experiment_duration_minutes*60))
  progress_step=$(awk "BEGIN {print $duration_sec / 100}")

  for i in {1..100}; do
    printf "\rProgress: [%-50s] %d%%" $(printf '#%.0s' $(seq 1 $((i/2)))) "$i"
    sleep "$progress_step"
  done
  echo # prints a new line after the progress bar
else
  echo "Begin polling the locust-parameter-variation.log to check if the load test was finished ('Finished performance test.')"
  sleep 10

  file_path="locust_logs/ad_workload/locust-parameter-variation.log"

  # Loop until the last line contains "Finished performance test"
  last_line=""
  while true; do
    # Check if the file exists
    if [[ ! -f "$file_path" ]]; then
      echo "Warning: File '$file_path' does not exist. Retrying ..."
    else
      if [[ -z "$last_line" ]]; then
        echo "File '$file_path' found. Waiting until performance test is finished ..."
      fi
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
fi


echo "Experiment completed."
sleep 1
cleanup
