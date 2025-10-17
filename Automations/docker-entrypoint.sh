#!/bin/bash

set -e

function activate_venv_in_current_dir {
  # Check if the "venv" folder exists
  if [ ! -d "venv" ]; then
    echo "The 'venv' folder does not exist. Exiting."
    exit 1
  fi

  # Debug: Show venv contents
  echo "Contents of venv/bin before activation:"
  ls -la venv/bin

  # Activate the virtual environment - this should set PATH and env vars
  # source venv/bin/activate
  . venv/bin/activate

  # Check if the virtual environment was activated successfully
  if [ $? -eq 0 ]; then
    echo "Virtual environment 'venv' activated successfully."
    echo "PATH after activation: $PATH"
    echo "VIRTUAL_ENV after activation: $VIRTUAL_ENV"
  else
    echo "Failed to activate the virtual environment 'venv'. Exiting."
    exit 1
  fi
}

echo "Effective file descriptor limit: $(ulimit -n)"
echo "try raising soft limit if allowed"
ulimit -n 65536 || echo "Could not raise nofile limit"
echo "Effective file descriptor limit: $(ulimit -n)"

echo "Initial environment:"
echo "PATH: $PATH"
echo "Contents of /app:"
ls -la

echo "Contents of /logs:"
ls /logs -la

echo "Contents of locust_logs/ad_workload and locust_logs/prod_workload:"
ls locust_logs/ad_workload -la 2>/dev/null || echo "locust_logs/ad_workload directory does not exist"
ls locust_logs/prod_workload -la 2>/dev/null || echo "locust_logs/prod_workload directory does not exist"
rm -rfv locust_logs/* 

# Activate the virtual environment
activate_venv_in_current_dir

echo "$(readlink -f venv/bin/python3)"
echo "$(readlink -f python)"

# Debug Python availability
echo "Python in venv/bin directory:"
ls -la venv/bin/python* 2>/dev/null || echo "No Python executables found"
echo "Python in PATH:"
which python 2>/dev/null || echo "python not found in PATH"
echo "Trying to run Python:"
python --version 2>&1 || echo "Cannot execute python directly"

echo "CMD to run: $@"

# Run the user command in background
"$@" &

main_pid=$!

echo "PID: $main_pid"

# Define cleanup handler
cleanup() {
  echo "Caught SIGTERM, terminating background process (PID=$main_pid)..."
  kill -TERM "$main_pid" 2>/dev/null

  echo "Waiting for backround to terminate..."

  # calling wait here, will exit the script with exit code 143 because we explicitly killed the process. So, we disable "exit on error" behavior.
  set +e
  wait "$main_pid"
  exit_code=$?
  echo "wait returned with status $exit_code"

  echo "Background process terminated."
  echo "Perform final copy of log files"

  # Final copy after command ends
  cp /app/*.log /logs/ 2>/dev/null

  echo "Done, exiting with 0"

  exit 0
}

# Trap SIGTERM and SIGINT
trap cleanup SIGTERM SIGINT

echo "Periodically copy updated logs from /app to /logs"
while kill -0 $main_pid 2>/dev/null; do

  for f in /app/*.log; do
    [ -e "$f" ] || continue
    cp "$f" /logs/
    sleep 0.01
  done

  sleep 1
done

echo "Background process finished."
echo "Perform final copy"

# Final copy after command ends
cp /app/*.log /logs/ 2>/dev/null

wait $main_pid || true

exit 0
