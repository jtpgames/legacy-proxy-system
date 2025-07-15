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

apt-get update && apt-get install -y iproute2 netcat-openbsd 
tc -V

# Increase max open files (necessary for performance experiment that creates a lot of sockets)
echo "Before: $(ulimit -n)"
ulimit -n 65536 || echo "Failed to increase ulimit"
echo "After: $(ulimit -n)"

# Install Python dependencies and run script
pip install -r requirements.txt

# Limit all incoming and outgoing network to 1mbit/s
#
# # Set up ingress policing (incoming traffic limit)
tc qdisc add dev eth0 ingress
tc filter add dev eth0 parent ffff: protocol ip prio 50 u32 match ip src 0.0.0.0/0 police rate 1mbit burst 10k drop flowid :1

# Set up TBF for egress shaping (outgoing traffic limit)
tc qdisc add dev eth0 root tbf rate 1mbit latency 25ms burst 10k

python "$1"
