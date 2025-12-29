#!/usr/bin/env bash

set -e
set -o pipefail

# forces programs to use the POSIX “C” locale, which defines the numeric format as:
# Decimal point: .
# No thousands separator
# No grouping
# This is important for awk and possibly other tools to use the same numeric format regardless of system locale
export LC_NUMERIC=C

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

# Function to compare version numbers
version_lt() {
  [ "$1" = "$2" ] && return 1
  # Compare two version strings using sort -V (version sort) 
  # which sorts the two version numbers in ascending order meaning head -n1 returns the smallest of the two numbers.
  # So when the first number passed to the function is equal to head -n1 is means the first number is less than the second number.
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

execute_docker_compose() {
  # Determine host OS and export it
  if [[ "$(uname -s)" == "Linux" ]]; then
    export HOST_OS=linux
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    export HOST_OS=mac
  else
    export HOST_OS=other
  fi

  if command -v podman &>/dev/null; then
    echo "Podman is installed. Using docker-compose." >&2
    docker-compose "$@"
    return 0
  fi

  # Get Docker version
  DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)

  if [[ -z "$DOCKER_VERSION" ]]; then
    echo "Error: Docker not running or not installed." >&2
    return 1
  fi

  # Check if Docker version is less than 27.0.0
  if version_lt "$DOCKER_VERSION" "27.0.0"; then
    # Use docker-compose for versions below 27.0.0
    echo "Docker version $DOCKER_VERSION detected. Using docker-compose." >&2
    docker-compose "$@"
  else
    # Use docker compose for versions 27.0.0 and above
    echo "Docker version $DOCKER_VERSION detected. Using docker compose." >&2
    docker compose "$@"
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

convert_to_epoch() {
  local timestamp="$1"
  local epoch

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: use `-j -f` to parse datetime string, output seconds since epoch
    # Example timestamp format: "2025-07-05 16:55:56.284"
    # We ignore fractional seconds since macOS date does not support them directly
    epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "${timestamp%%.*}" "+%s")
  else
    # GNU/Linux: use -d and parse full timestamp with fractional seconds truncated
    epoch=$(date -u -d "${timestamp%%.*}" "+%s")
  fi

  echo "$epoch"
}

convert_to_epoch_ms() {
  local ts="$1"
  python -c "
import sys
from datetime import datetime
ts = sys.argv[1]
dt = datetime.strptime(ts, '%Y-%m-%d %H:%M:%S.%f')
print(int(dt.timestamp() * 1000))
  " "$ts"
}

convert_to_epoch_ms_2() {
  python - "$@" <<'EOF'
import sys
from datetime import datetime

for ts in sys.argv[1:]:
    dt = datetime.strptime(ts, '%Y-%m-%d %H:%M:%S.%f')
    print(int(dt.timestamp() * 1000))
EOF
}


# Extract timestamp from a log line
extract_ts() {
  local line="$1"
  [[ $line =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3}) ]] && echo "${BASH_REMATCH[1]}"
}

# Extract a unix timestamp from a string with the following format: <TIMESTAMP>|<rest of the string>
extract_epoch() {
  local input="$1"

  # Extract the part before the first pipe
  # local epoch=$(echo "$input" | cut -d'|' -f1)
  local epoch="${input%%|*}"  # Get everything before first '|'

  # Validate: must be a number
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    echo "$epoch"
  else
    echo "Error: Invalid epoch timestamp: $epoch" >&2
    return 1
  fi
}

extract_file_name() {
  local input="$1"

  # Extract the part after the first pipe and before the second pipe
  # local file=$(echo "$input" | cut -d'|' -f2)

  local rest="${input#*|}"     # Remove up to first '|'
  local file="${rest%%|*}"     # Keep up to next '|'

  echo "$file"
}

calculate_time_difference_between_sending_and_finish_processing() {
  echo "-- calculate_time_difference_between_sending_and_finish_processing --"

  if [[ "$skip_calculating_time_difference_between_services" == "true" ]]; then
    echo "Skipped"
    return
  fi

  cd "$root_folder/Automations/$target_folder_for_logs"

  if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
    count_request_ids_load_tester=$(perl -n -e 'print "[$1] $2\n" if /\[([^]]+)].*\((\d+)\)\sSending to.*7081/' LoadTester_Logs/locust_log_1.log \
      | sed 's/,/./' \
      | sort -u \
      | tee request_ids_load_tester_send.txt \
      | wc -l)
  else
    # Save current nullglob state
    nullglob_was_set=$(shopt -p nullglob)

    # Enable nullglob state (If worker_*.log matches no files, the pattern expands to nothing ('') instead of remaining a literal string.)
    shopt -s nullglob

    files=(LoadTester_Logs/worker_*.log)
    if (( ${#files[@]} > 0 )); then
      count_request_ids_load_tester=$(perl -n -e 'print "[$1] $2\n" if /\[([^]]+)].*\((\d+)\)\sSending to.*7081/' "${files[@]}" \
        | sed 's/,/./' \
        | sort -u \
        | tee request_ids_load_tester_send.txt \
        | wc -l)
    fi

    # Restore original nullglob state
    eval "$nullglob_was_set"
  fi

  count_file2=$(perl -n -e 'print "[$1] $2\n" if /]\s(.+)\s\[.+UID:\s([^,]+),\s*CMD-ENDE\s*ID_REQ_KC_STORE7D3BPACKET/' \
    Simulator_Logs/gs_simulation.log \
    | sort -u \
    | tee request_ids_simulator_finish_processing.txt \
    | wc -l)

  log_files=(
    $(find LoadTester_Logs -type f \( -name "locust_log_*.log" -o -name "worker*.log" \))
    $(find LegacyProxy_Logs -type f -name "ars-comp*.log")
  )

  if [[ "$experiment_type" == "legacy" ]]; then
    log_files+=($(find LegacyProxy_Logs -type f -name "proxy*.log"))
  else
    log_files+=($(find LegacyProxy_Logs -type f -name "proxy1-*.log"))
    log_files+=($(find LegacyProxy_Logs -type f -name "proxy2-*.log"))
  fi

  log_files+=($(find Simulator_Logs -type f -name "*.log"))

  echo "log_files: ${log_files[@]}"
 
  # if [[ "$(uname)" == "Darwin" ]]; then
    # export MallocGuardEdges=1
    # export MallocScribble=1
    # export MallocStackLogging=1
    # export MallocCheckHeapStart=0
    # export MallocCheckHeapEach=1000
  # fi

  declare -g -A deltas_by_group_sum
  declare -g -A deltas_by_group_count

  # count_request_ids_load_tester = 100%
  # 1                             = 100/count_request_ids_load_tester
  # current_iteration             = current_iteration*100/count_request_ids_load_tester => current_progress in %
  #
  # 50 hashes                     = 100%
  # 50/100                        = 1%
  # current_progress*50/100       = count_of_hashes

  local current_iteration=0
  while read -r line; do
    # Update progress bar
    local current_progress=$(echo "$current_iteration*100/$count_request_ids_load_tester" | bc)
    local count_of_hashes=$(echo "$current_progress*50/100" | bc)

    local bar=$(printf '#%.0s' $(seq 1 $count_of_hashes))
    printf "\rProgress: [%-50s] %3d%%" "$bar" "$current_progress"
    ((current_iteration++))

    IFS=$'\t' read -r r_ts r_id < <(echo "$line" | perl -n -e 'print "$1\t$2\n" if /\[([^]]+)]\s+(\d+)/')

    if [[ "$with_fault_injector" == "false" ]]; then
      calculate_network_latencies_between_services_for_request_id "$r_id" "${log_files[@]}"
    fi

    # Find corresponding line
    match=$(rg -F "$r_id" "request_ids_simulator_finish_processing.txt")

    if [[ -n "$match" ]]; then
      processed_ts=$(echo "$match" | perl -n -e 'print "$1\n" if /\[([^]]+)]/')

      mapfile -t epochs < <(convert_to_epoch_ms_2 "$r_ts" "$processed_ts")
      epoch_a="${epochs[0]}"
      epoch_b="${epochs[1]}"

      # Compute time difference
      diff=$(echo "$epoch_b - $epoch_a" | bc)

      local group="20. LoadTester → Simulator"
      ((deltas_by_group_sum["$group"] += diff))
      ((deltas_by_group_count["$group"]++))

      # printf "ID: $r_id LoadTester → Simulator Δt = ${diff}ms\n"
    else
      echo "ID: $r_id → not found" 
    fi
    sleep 0.001
  done < "request_ids_load_tester_send.txt"

  # Finalize progress bar
  printf "\rProgress: [%-50s] 100%%\n" "$(printf '#%.0s' $(seq 1 50))"

  echo ""
  echo "Average time differences between service file transitions:"

  # CSV output file
  csv_file="latency_report.csv"
  echo "group,samples,average_ms" > "$csv_file"  # CSV header

  for group in "${!deltas_by_group_sum[@]}"; do
    local sum=${deltas_by_group_sum[$group]}
    local count=${deltas_by_group_count[$group]}
    if (( count == 0 )); then
      echo "Error: Cannot compute average for group '$group' — count is zero."
    else
      avg=$((sum / count))
      echo "$group: avg = ${avg}ms over $count samples"
      echo "\"$group\",$count,$avg" >> "$csv_file"  # Write to CSV
    fi
  done
}

calculate_network_latencies_between_services_for_request_id() {
  # echo "-- calculate_network_latencies_between_services_for_request_id --"

  local log_id="$1"
  shift
  local files=("$@")

  local matches=()

  mapfile -t rg_results < <(rg "$log_id" "${files[@]}")

  matches_raw=()
  for file in "${files[@]}"; do
    for match in "${rg_results[@]}"; do
      [[ $match == "$file:"* ]] && { matches_raw+=("$match"); break; }
    done
  done

  # echo "${matches_raw[@]}"

  local count=1
  local prev_ts=""
  local prev_file=""
  for match in "${matches_raw[@]}"; do
    # Extract filename and matched line from rg output (format: filename:line)
    local filename=${match%%:*}
    local line=${match#*:}

    # Extract timestamp from line and normalize decimal separator to dot notation.
    local ts=$(extract_ts "$line")
    ts=${ts//,/.}

    # Convert timestamp to epoch ms
    local epoch_ts=$(convert_to_epoch_ms "$ts")

    matches+=("$epoch_ts|$filename|$line")

    if [[ -n "$epoch_ts" ]]; then
      if [[ -n "$prev_ts" ]]; then
        local diff=$((epoch_ts - prev_ts))
        local group="${count}. ${prev_file} -> ${filename}"
        ((count++))

        ((deltas_by_group_sum["$group"] += diff))
        ((deltas_by_group_count["$group"]++))

        # printf "ID: $log_id $group $epoch_ts - $prev_ts Δt = ${diff}ms\n"
      fi
      prev_ts="$epoch_ts"
      prev_file="$filename"
    else
      echo "Warning: No timestamp found in: $match"
    fi

  done

  # for match in "${matches[@]}"; do
  #   # printf "Match: %s\n" "$match"
  #
  #   # Extract timestamp
  #   local epoch_ts=$(extract_epoch "$match")
  #   local filename=$(extract_file_name "$match")
  #
  #   if [[ -n "$epoch_ts" ]]; then
  #     if [[ -n "$prev_ts" ]]; then
  #       local diff=$((epoch_ts - prev_ts))
  #       local group="${count}. ${prev_file} -> ${filename}"
  #       ((count++))
  #
  #       ((deltas_by_group_sum["$group"] += diff))
  #       ((deltas_by_group_count["$group"]++))
  #
  #       # printf "ID: $log_id $group $epoch_ts - $prev_ts Δt = ${diff}ms\n"
  #     fi
  #     prev_ts="$epoch_ts"
  #     prev_file="$filename"
  #   else
  #     echo "Warning: No timestamp found in: $match"
  #   fi
  # done
}

validate_equal_number_of_requests_send_and_received() {
  echo "-- validate_equal_number_of_requests_send_and_received --"

  cd "$root_folder/Automations/$target_folder_for_logs"
  # Create/clear the log file
  echo "-- validate_equal_number_of_requests_send_and_received --" > validate_equal_number_of_requests_send_and_received.log
  echo "Determining if all requests that have been sent by the load tester have been successfully received and processed by the Simulator..." | tee -a validate_equal_number_of_requests_send_and_received.log
  # Count matches in LoadTester_Logs (for failover experiment locust_log_1.log, for performance experiment every file matching the pattern worker_*.log)
  # the following regex captures the request-id enclosed in () from the capture group (\d+) and only for the first send to the first server (7081)
  # ignoring retries to the other servers.
  echo "Determining distinct request-ids..." | tee -a validate_equal_number_of_requests_send_and_received.log

  if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
    # Example: [2025-10-21 21:24:56,655] d0c925dc74e7/INFO/RepeatingClient: [213574268831903652950313345009142188478] (213574357567445668926371449778366564798) Sending to http://host.docker.internal:7081/api/v1/simple
    count_request_ids_load_tester=$(perl -n -e 'print "$1\n" if /\((\d+)\)\sSending to.*7081/' LoadTester_Logs/locust_log_1.log | sort -u | tee request_ids.txt | wc -l)
  else
    # Save current nullglob state
    nullglob_was_set=$(shopt -p nullglob)

    # Enable nullglob state (If worker_*.log matches no files, the pattern expands to nothing ('') instead of remaining a literal string.)
    shopt -s nullglob

    files=(LoadTester_Logs/worker_*.log)
    if (( ${#files[@]} > 0 )); then
      count_request_ids_load_tester=$(perl -n -e 'print "$1\n" if /\((\d+)\)\sSending to.*708./' "${files[@]}" | sort -u | tee request_ids.txt | wc -l)
      # here, we look for sends to all servers because we randomly send in the performance experiment. 
      # However, because we stop the load test, we typically have a lot of send requests that never reached the server because the load tester processes are killed. Maybe, it is a bug in locust. So here, we look for the requests where we received responses.
      # Example: [2025-10-21 21:24:56,715] d0c925dc74e7/INFO/RepeatingClient: [213574268831903652950313345009142188478] (213574357567445668926371449778366564798) Response time 59 ms
      # count_request_ids_load_tester=$(perl -n -e 'print "$1\n" if /\((\d+)\)\sResponse time/' "${files[@]}" | sort -u | tee request_ids.txt | wc -l)
    fi

    # Restore original nullglob state
    eval "$nullglob_was_set"
  fi

  echo "Count corresponding matches in Simulator_Logs/gs_simulation.log" | tee -a validate_equal_number_of_requests_send_and_received.log
  # count_file2=$(sed 's/$/, CMD-ENDE/' request_ids.txt | grep -Ff - Simulator_Logs/gs_simulation.log | wc -l)
  count_file2=$(sed 's/$/, CMD-ENDE/' request_ids.txt | rg --fixed-strings --file=- Simulator_Logs/gs_simulation.log | wc -l)

  echo "Number of received alarm messages:" | tee -a validate_equal_number_of_requests_send_and_received.log
  alarm_count=$(grep -c "200 OK:.*ID_REQ_KC_STORE.*" "Simulator_Logs/gs_simulation.log")
  echo "$alarm_count" | tee -a validate_equal_number_of_requests_send_and_received.log

  rg -o 'UID:\s([^,]+),\s*CMD-ENDE\s*ID_REQ_KC_STORE7D3BPACKET' Simulator_Logs/gs_simulation.log \
    | sed -E 's/UID:[[:space:]]([^,]+),[[:space:]]*CMD-ENDE[[:space:]]*ID_REQ_KC_STORE7D3BPACKET/\1/' \
    | sort -u \
    > request_ids_simulator.txt

  echo "Request-Ids only in request_ids.txt" | tee -a validate_equal_number_of_requests_send_and_received.log
  # comm -23 request_ids.txt request_ids_simulator.txt | tee -a validate_equal_number_of_requests_send_and_received.log
  echo "Request-Ids only in request_ids_simulator.txt" | tee -a validate_equal_number_of_requests_send_and_received.log
  # comm -13 request_ids.txt request_ids_simulator.txt | tee -a validate_equal_number_of_requests_send_and_received.log

  echo "Request-Ids in locust_log_1.log: $count_request_ids_load_tester" | tee -a validate_equal_number_of_requests_send_and_received.log
  echo "Matches in gs_simulation.log: $count_file2" | tee -a validate_equal_number_of_requests_send_and_received.log
  if [ "$count_request_ids_load_tester" -eq "$count_file2" ]; then
    echo "Number of requests matches." | tee -a validate_equal_number_of_requests_send_and_received.log
  fi
}

determine_maximum_parallel_requests_received_at_targetservice() {
  echo "-- determine_maximum_parallel_requests_received_at_targetservice --"  
  
  cd "$root_folder/Automations/$target_folder_for_logs"

  # Search for lines like X: {PR 1=2, PR 3=0, Request Type=9.0}
 
  perl -ne '
  if (/\{PR 1=(\d+),.*Request Type=([\d.]+).*}/) {
    $pr1 = $1;
    $req = $2;
    $max{$req} = $pr1 if !defined($max{$req}) || $pr1 > $max{$req};
  }
  END {
    foreach $req (sort { $a <=> $b } keys %max) {
      printf "Request Type %s: max PR 1 = %d\n", $req, $max{$req};
    }
  }
' Simulator_Logs/gs_simulation.log


  # Not compatible with BSD awk
#   awk '
#   /\{PR 1=[0-9]+,.*Request Type=[0-9.]+/ {
#     match($0, /\{PR 1=([0-9]+),.*Request Type=([0-9.]+)/, m)
#     pr1 = m[1] + 0
#     req = m[2]
#     if (pr1 > max[req]) {
#       max[req] = pr1
#     }
#   }
#   END {
#     for (r in max) {
#       print r, max[r]
#     }
#   }
# ' Simulator_Logs/gs_simulation.log | sort -n | awk '{ printf "Request Type %s: max PR 1 = %s\n", $1, $2 }'

}

# Function to cleanup resources
cleanup() {
    set +e
    echo -e "\nCleaning up..."

    # prevent calling cleanup again when inside here.
    trap - SIGINT SIGTERM

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
    pgrep -f 'python inject_fault.py' | xargs -r kill -TERM
    sleep 1
    screen -S inject_fault_session_ars_1 -X quit 2>/dev/null || true
    screen -S inject_fault_session_ars_2 -X quit 2>/dev/null || true
    screen -S inject_fault_session_ars_3 -X quit 2>/dev/null || true
    screen -S inject_fault_session_2 -X quit 2>/dev/null || true

    echo "Stopping load testers and waiting for an additional 10 seconds grace period"
    docker stop prod_workload_container ad_workload_container 2>/dev/null || true
    sleep 10

    if [[ "$experiment_type" == "ng" ]]; then
      echo "Waiting for another 2 minutes for the remaining messages in the broker to be consumed."
      sleep 120
    fi

    echo "Stopping all containers..."
    execute_docker_compose down --remove-orphans

    if [[ "${1}" != "no_exit" ]]; then
      echo "collect the results"

      echo "from legacy_proxies"
      echo "to Automations/$target_folder_for_logs ..."

      # here we are still in the python folder
      mkdir -pv "$root_folder/Automations/$target_folder_for_logs/LegacyProxy_Logs"
      mv -v "logs/"* "$root_folder/Automations/$target_folder_for_logs/LegacyProxy_Logs"
      if [ -d "mosquitto-logs" ] && [ "$(find mosquitto-logs -type f | head -n 1)" ]; then
        mkdir -pv "$root_folder/Automations/$target_folder_for_logs/Broker_Logs"
        mv -v mosquitto-logs/* "$root_folder/Automations/$target_folder_for_logs/Broker_Logs"
      elif [ -d "hivemq-logs" ] && [ "$(find hivemq-logs -type f | head -n 1)" ]; then
        mkdir -pv "$root_folder/Automations/$target_folder_for_logs/Broker_Logs"
        mv -v hivemq-logs/* "$root_folder/Automations/$target_folder_for_logs/Broker_Logs"
      fi

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
        echo "python loadtest_plotter.py \"$root_folder/Automations/$target_folder_for_logs/LoadTester_Logs/locust_log_1.log\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_stop_once\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_1\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_2\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_3\" \
          -o \"$root_folder/Automations/$target_folder_for_logs/results_$failover_or_performance_load.pdf\""
        
        python loadtest_plotter.py "$root_folder/Automations/$target_folder_for_logs/LoadTester_Logs/locust_log_1.log" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_stop_once" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_1" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_2" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_3" \
          -o "$root_folder/Automations/$target_folder_for_logs/results_$failover_or_performance_load.pdf"

          validate_equal_number_of_requests_send_and_received
          calculate_time_difference_between_sending_and_finish_processing
      else
        echo "python loadtest_plotter.py \"$root_folder/Automations/$target_folder_for_logs/LoadTester_Logs/locust-parameter-variation.log\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_stop_once\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_1\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_2\" \
          -f \"$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_3\" \
          -o \"$root_folder/Automations/$target_folder_for_logs/results_$failover_or_performance_load.pdf\""
        
        python loadtest_plotter.py "$root_folder/Automations/$target_folder_for_logs/LoadTester_Logs/locust-parameter-variation.log" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_stop_once" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_1" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_2" \
          -f "$root_folder/Automations/$target_folder_for_logs/$fault_injector_logfile_name_ars_3" \
          -o "$root_folder/Automations/$target_folder_for_logs/results_$failover_or_performance_load.pdf"

          validate_equal_number_of_requests_send_and_received
          calculate_time_difference_between_sending_and_finish_processing
          determine_maximum_parallel_requests_received_at_targetservice
      fi

      # to trace a request do the following:
      # 1. retrieve the request-id of the request you want to trace from the load tester logs, then
      # for fail over test
      # For Baseline experiment
      # grep "request-id" LoadTester_Logs/locust_log_1.log LegacyProxy_Logs/ars-comp-1-1.log LegacyProxy_Logs/proxy-1.log Simulator_Logs/gs_simulation.log
      # for NG experiment
      # grep "request_id" LoadTester_Logs/locust_log_1.log LegacyProxy_Logs/ars-comp-1-1.log LegacyProxy_Logs/proxy1-1.log LegacyProxy_Logs/proxy2-1.log Simulator_Logs/gs_simulation.log
      # for performance test
      # grep "request-id" LoadTester_Logs/worker_log_500.1.log LegacyProxy_Logs/ars-comp-1-1.log LegacyProxy_Logs/proxy-1.log Simulator_Logs/gs_simulation.log
    fi

    echo "Cleanup completed."
    set -e
}

# Function to check if services are running
check_services_running() {
  output=$(execute_docker_compose ps --quiet)

  if grep -q . <<< "$output"; then
    echo "Services are already running."
    return 0
  fi

  return 1
}

wait_until_all_files_exist() {
  local log_dir=$1
  shift
  local expected_files=("$@")

  echo "Waiting for all log files to be created in $log_dir..."

  while true; do
    all_exist=true
    for file in "${expected_files[@]}"; do
      if [[ ! -f "$log_dir/$file" ]]; then
        all_exist=false
        break
      fi
    done

    if $all_exist; then
      echo "All expected log files are present: ${expected_files[@]}"
      break
    fi

    sleep 1
  done
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

# -- Global variables --
skip_calculating_time_difference_between_services=true
fault_injector_logfile_base_name="fault_injector"
failover_load_type="failover"
performance_load_type="performance"
# set via CLI args
run_cleanup=false
verbose=false
experiment_type="legacy"  # Default to legacy
with_fault_injector=false
include_timestamp_to_experiment_result_folder=true
failover_or_performance_load=''
# -- set before running an experiment
root_folder=''
target_folder_for_logs=''
# --

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
    # compose_file="docker-compose-ng.yml"
    compose_file="docker-compose-ng-hivemq.yml"
    docker volume rm python_hivemq-data 2>/dev/null || true
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

# set timezone environment variables in docker-compose file
local_timezone=$(readlink /etc/localtime | sed 's|/var/db/timezone/zoneinfo/||')

echo "Local Timezone: ${local_timezone}"

# Replace and update the file safely
echo "Setting TZ environment variable on ${compose_file}"
tmpfile=$(mktemp)
echo "Created temp file ${tmpfile}"
echo "Replace"
grep -E '^[[:space:]]*-\s*TZ=' "$compose_file"
echo "with"
grep -E '^[[:space:]]*-\s*TZ=' "$compose_file" | sed -E "s|^([[:space:]]*)-[[:space:]]*TZ=.*|\1- TZ=${local_timezone}|"

sed -E "s|^([[:space:]]*)-[[:space:]]*TZ=.*|\1- TZ=${local_timezone}|" "$compose_file" > "$tmpfile" && mv "$tmpfile" "$compose_file"

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
execute_docker_compose build
execute_docker_compose up -d

fault_injector_logfile_name_ars_1="${fault_injector_logfile_base_name}_ars_1.log"
fault_injector_logfile_name_ars_2="${fault_injector_logfile_base_name}_ars_2.log"
fault_injector_logfile_name_ars_3="${fault_injector_logfile_base_name}_ars_3.log"
fault_injector_logfile_name_stop_once="${fault_injector_logfile_base_name}_stop_once.log"

touch $fault_injector_logfile_name_ars_1
touch $fault_injector_logfile_name_stop_once
if [[ "$with_fault_injector" == "true" ]]; then
    echo "Fault Injector starting ..."
    activate_venv_in_current_dir

    duration_up=20
    maximum_recovery_time=37.5

    screen -dmS inject_fault_session_ars_1 bash -c \
      "python inject_fault.py --target-service ars-comp-1-1 \
      --fault-mode stop_once --duration-up 20 \
      > \"$fault_injector_logfile_name_ars_1\" 2>&1"

    screen -dmS inject_fault_session_ars_2 bash -c \
      "python inject_fault.py --target-service ars-comp-1-2 \
      --fault-mode stop_once --duration-up 20 \
      > \"$fault_injector_logfile_name_ars_2\" 2>&1"
    
    screen -dmS inject_fault_session_ars_3 bash -c \
      "python inject_fault.py --target-service ars-comp-1-3 \
      --fault-mode stop_once --duration-up 20 \
      > \"$fault_injector_logfile_name_ars_3\" 2>&1"
    
    time_before_starting_second_fault_injector_sec=$(echo "20 + $maximum_recovery_time" | bc)
    
    # Define service arrays
    ars_services=(ars-comp-1-1 ars-comp-1-2 ars-comp-1-3)
    legacy_proxies=(ars-comp-2-1)
    ng_legacy_proxies=(proxy1-1 proxy2-1 ars-comp-2-1)
    target_services=(ars-comp-3)

    # Select legacy proxies depending on experiment type
    if [[ "$experiment_type" == "legacy" ]]; then
      proxies=("${legacy_proxies[@]}")
    else
      proxies=("${ng_legacy_proxies[@]}")
    fi

    # Build combined service list
    all_services=("${ars_services[@]}" "${proxies[@]}" "${target_services[@]}")

    # A fault injector with fault-mode stop_once stops one "ars-comp-3" at a time, beginning after "duration_up" seconds.
    # The next service is stopped after the first recovered + duration_up seconds.
    # The maximum recovery time is calculated based on the configuration of the FaultAndRecoveryModel. 
    # # experiment_runtime = number_of_faults_to_inject * (duration_up + maximum_recovery_time)
    
    # Calculate required experiment runtime
    number_of_faults_to_inject=${#all_services[@]}
    experiment_runtime_seconds=$(awk -v n="$number_of_faults_to_inject" \
      -v up="$duration_up" \
      -v rec="$maximum_recovery_time" \
      'BEGIN { print n * (up + rec) }')

    experiment_runtime_seconds=$(echo "$experiment_runtime_seconds + $time_before_starting_second_fault_injector_sec" | bc)

    # perform integer cast to truncate and add 59 before dividing by 60, thus, implementing a ceiling function that
    # always rounds to the next minute.
    experiment_runtime_minutes=$(awk -v s="$experiment_runtime_seconds" \
      'BEGIN { print int((s + 59) / 60) }')

    echo "Number of services: $number_of_faults_to_inject"
    echo "Experiment runtime: $experiment_runtime_seconds seconds"
    echo "Experiment runtime: $experiment_runtime_minutes minutes"

    # Adjust experiment duration (overwrite user input)
    failover_experiment_duration_minutes=$experiment_runtime_minutes

    # Run fault injection
    screen -dmS inject_fault_session_2 bash -c \
      "python inject_fault.py $(printf -- '--target-service %s ' "${all_services[@]}") \
      --fault-mode stop_once --duration-up 20 --initial-wait $time_before_starting_second_fault_injector_sec \
      > \"$fault_injector_logfile_name_stop_once\" 2>&1"

    echo "Fault Injectors started"
else
    echo "Running without Fault Injectors"
fi

# Wait for services to be ready
echo "Waiting for services to start..."
# if [[ "$experiment_type" == "legacy" ]]; then
#   sleep 15
# else
#   sleep 20
# fi

# Verify that all ars-comp-1 instances have each created a log file. That way we know that all necessary services are running and ready.
log_dir="./logs"

# Define the list of expected log files
expected_files=(
  "ars-comp-1-1.log"
  "ars-comp-1-2.log"
  "ars-comp-1-3.log"
)

wait_until_all_files_exist "$log_dir" "${expected_files[@]}"

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
echo "Launching Production Background Workload directly on the last ARS component"

# Detect if running on Linux with Docker engine (not Podman)
ADD_HOST_FLAG=""
if [[ "$(uname -s)" == "Linux" ]] && ! docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi podman; then
  ADD_HOST_FLAG="--add-host=host.docker.internal:host-gateway"
fi

docker run -d \
  --name prod_workload_container \
  $ADD_HOST_FLAG \
  -v "$LOCUST_SCRIPTS_DIR/locust_logs/prod_workload:/logs" \
  -v /etc/localtime:/etc/localtime:ro \
  locust_scripts_runner:latest \
  bash -c "$cmd_prod_workload"

echo "Waiting 2 seconds so that the prod workload warms up the JVM-based ARS component..."
sleep 2 # for performance test make this longer to properly warm up?

echo "Launching Alarm Device workload to the first ARS component"
unset USE_RANDOM_ENDPOINT
if [[ "$failover_or_performance_load" == "$failover_load_type" ]]; then
  cmd_ad_workload='python locust-parameter-variation.py locust/gen_gs_alarm_device_workload_2.py -u http://host.docker.internal:7081,http://host.docker.internal:7082,http://host.docker.internal:7083 -m 1'
else
  USE_RANDOM_ENDPOINT=true
  cmd_ad_workload='python locust-parameter-variation.py locust/gen_gs_alarm_device_workload_2.py -u http://host.docker.internal:7081,http://host.docker.internal:7082,http://host.docker.internal:7083 -m 250 -p'
fi

docker run -d \
  --name ad_workload_container \
  $ADD_HOST_FLAG \
  ${USE_RANDOM_ENDPOINT:+-e USE_RANDOM_ENDPOINT=$USE_RANDOM_ENDPOINT} \
  -e USE_HTTP_2=true \
  -v "$LOCUST_SCRIPTS_DIR/locust_logs/ad_workload:/logs" \
  -v /etc/localtime:/etc/localtime:ro \
  locust_scripts_runner:latest \
  bash -c "$cmd_ad_workload"

# move to root folder
cd "$root_folder"

# move to python folder
cd python
echo -e "\nServices are running in docker containers."
execute_docker_compose ps
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
