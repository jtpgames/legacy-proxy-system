#!/usr/bin/env bash

# Function to display the help message
show_help() {
  echo -e "\e[32mThis script sets up and executes an experiment with RAST using the GS Alarm System Production Logs. The execution of the experiment takes approximately x hours.\n\e[0m\n"
  echo -e "Usage: $0 [OPTION]\n"
  echo "Options:"
  echo "  -c, --clean-start    Remove result directories and files before starting."
  echo "                       This results in a fresh start of the experiment, ensuring no previous data interferes."
  echo "  -h, --help           Display this help message and exit."
}

# Function to clean directories
clean_start() {
  echo "Cleaning directories..."
  rm -rv Baseline_Experiment/*
  rm -rv NG_Experiment/*
}

# Initialize flags
run_cleanup=false

# Check for the -c, --clean-start, -h, or --help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
  exit 0
elif [[ "$1" == "-c" || "$1" == "--clean-start" ]]; then 
  run_cleanup=true
  clean_start
fi

# Function to execute setup scripts
run_setup() {
  cd Setup
  ./setup.sh
  cd ../
}

run_baseline_experiment_failover() {
  if [[ "$run_cleanup" == true ]]; then
    ./start_experiment.sh --with_fault_injector --without_timestamp -t legacy failover 3
  else
    ./start_experiment.sh --with_fault_injector -t legacy failover
  fi
}

run_baseline_experiment_performance() {
  if [[ "$run_cleanup" == true ]]; then
    ./start_experiment.sh --without_timestamp -t legacy performance
  else
    ./start_experiment.sh -t legacy performance
  fi
}

run_broker_experiment_failover() {
  if [[ "$run_cleanup" == true ]]; then
    ./start_experiment.sh --with_fault_injector --without_timestamp -t ng failover 4
  else
    ./start_experiment.sh --with_fault_injector -t ng failover
  fi
}

run_broker_experiment_performance() {
  if [[ "$run_cleanup" == true ]]; then
    ./start_experiment.sh --without_timestamp -t ng performance
  else
    ./start_experiment.sh -t ng performance
  fi
}

# List of functions to be executed
functions=(
  "run_setup"
  # "run_baseline_experiment_failover"
  "run_baseline_experiment_performance"
  # "run_broker_experiment_failover"
  # "run_broker_experiment_performance"
)

source run_experiment.sh

run_experiment
