#!/bin/bash

# Check if a script argument is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <python_script.py>"
  exit 1
fi

if [ ! -f "$1" ]; then
  echo "Error: File '$1' not found."
  exit 1
fi

# Default: don't use Granian
USE_GRANIAN=false

# Check for the optional flag
if [ "$2" == "--use-granian" ]; then
  USE_GRANIAN=true
fi

apt-get update && apt-get install -y iproute2 netcat-openbsd bc
tc -V

# Defaults
download_rate_mbit="2"  # in mbit
latency_ms=10          # e.g., 100 for 100ms
upload_bandwidth="1"    # in mbit
egress_delay="40ms"
egress_jitter="10ms"

# Corporate WAN / MPLS (moderate latency, stable) according to ChatGPT 5

download_rate_mbit="100"
# upload_bandwidth="100" # (often symmetric)
# upload_bandwidth="50" # GS Corporate LAN
upload_bandwidth="5" # Customer LAN
latency_ms=30
egress_delay="30ms"
egress_jitter="3ms"
loss="0.01%"

# TODO: linkopts = {'bw': 50, 'delay': '7.97ms', 'jitter': '2.9ms'}

# Calculate burst = (rate in bits per second * latency in seconds) / 8
rate_bit=$((download_rate_mbit * 1000 * 1000))
latency_sec=$(echo "$latency_ms / 1000" | bc -l)

echo "$rate_bit * $latency_sec / 8"
burst_bytes=$(echo "$rate_bit * $latency_sec / 8" | bc -l)

# Round to nearest integer
burst_rounded=$(printf "%.0f" "$burst_bytes")
echo $burst_rounded

download_burst=$(($burst_rounded / 1000))
echo $download_burst

# Calculate burst = (rate in bits per second * latency in seconds) / 8
rate_bit=$((upload_bandwidth * 1000 * 1000))
latency_sec=$(echo "$latency_ms / 1000" | bc -l)

burst_bytes=$(echo "$rate_bit * $latency_sec / 8" | bc -l)

# Round to nearest integer
burst_rounded=$(printf "%.0f" "$burst_bytes")

upload_burst=$(($burst_rounded / 1000))

apt-get update && apt-get install -y iproute2 netcat-openbsd 
tc -V

# Increase max open files (necessary for performance experiment that creates a lot of sockets)
echo "Before: $(ulimit -n)"
ulimit -n 65536 || echo "Failed to increase ulimit"
echo "After: $(ulimit -n)"

# Install Python dependencies
pip install --root-user-action=ignore -r requirements.txt

# Limit all incoming and outgoing network
# Simulate ADSL link
tc qdisc add dev eth0 ingress

echo "Set up ingress policing (incoming traffic limit) with rate ${download_rate_mbit}mbit burst ${download_burst}k"
tc filter add dev eth0 parent ffff: protocol ip prio 50 u32 match ip src 0.0.0.0/0 police rate "${download_rate_mbit}mbit" burst "${download_burst}k" drop flowid :1

echo "Apply TBF for uplink/egress shaping (limited upload/outgoing rate) with rate ${upload_bandwidth}mbit burst ${upload_burst}k latency ${latency_ms}ms"
tc qdisc add dev eth0 root handle 1: tbf rate "${upload_bandwidth}mbit" burst "${upload_burst}k" latency "${latency_ms}ms"

# netem only works on linux host (not VM on MacOS)
if [[ "$HOST_OS" == "linux" ]]; then
  echo "Linux host detected."
  echo "Add netem to simulate latency and jitter with delay $egress_delay $egress_jitter distribution normal loss $loss 25% (Gilbert-Elliot loss models)"
  # tc qdisc add dev eth0 parent 1:1 handle 10: netem delay $egress_delay $egress_jitter distribution normal
  tc qdisc add dev eth0 parent 1:1 handle 10: netem delay $egress_delay $egress_jitter distribution normal loss $loss 25%
else
  echo "Non-Linux host detected."
fi

# Try to use tc to simulate these links that we simulated in other experiments using mininet.
# # Simulate production system
# # customer has 1 Gigabit Ethernet (GbE) connection to his router
# linkopts = {'bw': 1000, 'delay': '0.45ms'}
# self.addLink(locust_runner, customerSwitch, **linkopts)
#
# # customer has VDSL 100 (100 MBit Download, 30 MBit Upload)
# linkopts = {'bw': 30, 'delay': '2.4ms', 'jitter': '5.2ms'}
# self.addLink(customerSwitch, ispCustomerSwitch, **linkopts)
#
# # ISP Interlink (10 GbE connection)
# # 1 Gigabit is the maximum bandwidth allowed by mininet
# linkopts = {'bw': 1000, 'delay': '13.3ms', 'jitter': '3.15ms'}
# self.addLink(ispCustomerSwitch, ispAPSwitch, **linkopts)
#
# # alarm provider sadly does NOT have SDSL, rather LACP-based Uplinks: VDSL100, VDSL50 combined
# linkopts = {'bw': 50, 'delay': '7.97ms', 'jitter': '2.9ms'}
# self.addLink(ispAPSwitch, self.apSwitch, **linkopts)


if $USE_GRANIAN; then
  echo "Running with Granian..."
  pip install --root-user-action=ignore granian
  # Extract the base filename without directory or .py extension
  SCRIPT_NAME=$(basename "$1" .py)

  # Read environment variables with defaults
  HOST="${HTTP_HOST:-0.0.0.0}"
  PORT="${HTTP_PORT:-8080}"
  
  # Determine if HTTP/2 should be used
  HTTP_FLAG=""
  if [[ "${USE_HTTP_2,,}" == "true" || "${USE_HTTP_2}" == "1" || "${USE_HTTP_2,,}" == "yes" ]]; then
    HTTP_FLAG="--http 2"
  fi

  echo "granian --interface asgi --host \"$HOST\" --port \"$PORT\" $HTTP_FLAG \"${SCRIPT_NAME}:app\""

  granian --interface asgi --host "$HOST" --port "$PORT" $HTTP_FLAG "${SCRIPT_NAME}:app"
else
  echo "Running univorn..."
  python "$1"
fi

