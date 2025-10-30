#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAME="retry-priority-extension"
EXTENSIONS_DIR="${SCRIPT_DIR}/hivemq_broker/extensions"

echo "======================================================"
echo "MQTT Testing: With and Without Retry Extension"
echo "======================================================"
echo ""

# Test 1: Without extension
echo "=== TEST 1: WITHOUT RETRY EXTENSION ==="
echo ""
echo "Cleaning previous extension installation ..."
rm -rfv "${EXTENSIONS_DIR}/${EXTENSION_NAME}"

echo ""
echo "Starting HiveMQ without extension..."
docker-compose down
docker-compose up -d --build

echo ""
echo "Waiting for HiveMQ to be ready..."
sleep 10

echo ""
echo "Running MQTT tests WITHOUT extension..."
./test_mqtt.sh

echo ""
echo "✅ Test without extension completed!"
echo ""
echo "======================================================"
echo ""

# Test 2: With extension
echo "=== TEST 2: WITH RETRY EXTENSION ==="
echo ""
echo "Building and starting HiveMQ with extension..."
./build_and_start_hivemq.sh

echo ""
echo "Waiting for HiveMQ to be ready..."
sleep 10

echo ""
echo "Running MQTT tests WITH extension..."
./test_mqtt.sh

echo ""
echo "✅ Test with extension completed!"
echo ""
echo "======================================================"
echo "All tests completed!"
echo "======================================================"
