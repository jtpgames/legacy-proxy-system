#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIVEMQ_HOST="hivemq"
MQTT_PORT="1883"

# Get the network name from docker-compose
NETWORK_NAME="${SCRIPT_DIR##*/}_default"

echo "Testing HiveMQ MQTT broker..."
echo "Network: ${NETWORK_NAME}"
echo ""

# Test 1: Basic connectivity test
echo "=== Test 1: Basic Connectivity ==="
echo "Starting subscriber on topic 'test/topic'..."
docker run --rm -d \
    --name mqtt-subscriber \
    --network "${NETWORK_NAME}" \
    eclipse-mosquitto:latest \
    mosquitto_sub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" -t "test/topic" -v

sleep 2

echo "Publishing message to 'test/topic'..."
docker run --rm \
    --network "${NETWORK_NAME}" \
    eclipse-mosquitto:latest \
    mosquitto_pub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" -t "test/topic" -m "Hello from MQTT test!"

sleep 1

echo "Subscriber logs:"
docker logs mqtt-subscriber

echo "Cleaning up subscriber..."
docker stop mqtt-subscriber 2>/dev/null || true

echo ""
echo "✅ Test 1 completed!"
echo ""

# Test 2: Retry message priority test
echo "=== Test 2: Retry Message Priority ==="
echo "This test verifies that retry messages are consumed before normal messages."
echo ""

# Define topics (publishers use normal topics, subscribers use $share prefix)
PUBLISH_NORMAL_TOPIC="service1/message"
PUBLISH_RETRY_TOPIC="service1/retry/message"
CLIENT_ID="test-subscriber-$$"

# Step 0: Establish persistent session by connecting briefly then disconnecting
echo "Step 0: Establishing persistent session for client '${CLIENT_ID}'..."
docker run --rm \
    --network "${NETWORK_NAME}" \
    eclipse-mosquitto:latest \
    timeout 1 mosquitto_sub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" \
    -i "${CLIENT_ID}" \
    -c \
    -t "\$share/legacy_proxy/+/message" \
    -t "\$share/legacy_proxy/+/retry/message" \
    -q 2 || true

echo "Persistent session established. Messages will now be queued."
echo ""

# Step 1: Publish normal messages
echo "Step 1: Publishing 5 normal messages to '${PUBLISH_NORMAL_TOPIC}'..."
for i in {1..5}; do
    docker run --rm \
        --network "${NETWORK_NAME}" \
        eclipse-mosquitto:latest \
        mosquitto_pub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" -t "${PUBLISH_NORMAL_TOPIC}" -m "Normal-$i" -q 2
    echo "  Published: Normal-$i"
done

echo ""

# Step 2: Publish retry messages
echo "Step 2: Publishing 3 retry messages to '${PUBLISH_RETRY_TOPIC}'..."
for i in {1..3}; do
    docker run --rm \
        --network "${NETWORK_NAME}" \
        eclipse-mosquitto:latest \
        mosquitto_pub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" -t "${PUBLISH_RETRY_TOPIC}" -m "Retry-$i" -q 2
    echo "  Published: Retry-$i"
done

echo ""

# Step 3: Wait for messages to be queued
echo "Step 3: Waiting for messages to be queued in broker..."
sleep 2

# Step 4: Subscribe and collect all messages
echo "Step 4: Starting subscriber to collect all messages..."
echo "Expected order: Retry-1, Retry-2, Retry-3, then Normal-1, Normal-2, Normal-3, Normal-4, Normal-5"
echo ""

# Create a temporary file for collecting messages
TEMP_FILE="/tmp/mqtt_test_output_$$.txt"

# Start subscriber in background and save output
# Use -c for persistent session and -i for client ID to queue messages while offline
docker run --rm -d \
    --name mqtt-order-subscriber \
    --network "${NETWORK_NAME}" \
    eclipse-mosquitto:latest \
    mosquitto_sub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" \
    -i "${CLIENT_ID}" \
    -c \
    -t "\$share/legacy_proxy/+/message" \
    -t "\$share/legacy_proxy/+/retry/message" \
    -q 2 -v

# Wait for messages to be received
echo "Collecting messages for 5 seconds..."
sleep 5

# Get subscriber logs
echo "Received messages in order:"
docker logs mqtt-order-subscriber 2>&1 | tee "${TEMP_FILE}"

echo ""
echo "=== Analysis ==="

# Extract message order
MESSAGES=$(docker logs mqtt-order-subscriber 2>&1 | grep -E "(Normal-|Retry-)" || true)

if [ -z "$MESSAGES" ]; then
    echo "❌ No messages received! Check broker configuration."
    exit 1
else
    # Count retry and normal messages
    RETRY_COUNT=$(echo "$MESSAGES" | grep -c "Retry-" || echo "0")
    NORMAL_COUNT=$(echo "$MESSAGES" | grep -c "Normal-" || echo "0")
    
    echo "Messages received:"
    echo "  Retry messages: $RETRY_COUNT/3"
    echo "  Normal messages: $NORMAL_COUNT/5"
    echo ""
    
    # Check if retry messages came first
    FIRST_NORMAL_LINE=$(echo "$MESSAGES" | grep -n "Normal-" | head -1 | cut -d: -f1 || echo "999")
    LAST_RETRY_LINE=$(echo "$MESSAGES" | grep -n "Retry-" | tail -1 | cut -d: -f1 || echo "0")
    
    if [ "$RETRY_COUNT" -eq 3 ] && [ "$NORMAL_COUNT" -eq 5 ]; then
        if [ "$LAST_RETRY_LINE" -lt "$FIRST_NORMAL_LINE" ] || [ "$FIRST_NORMAL_LINE" -eq "999" ]; then
            echo "✅ SUCCESS: All retry messages were consumed before normal messages!"
        else
            echo "⚠️  WARNING: Message order may be incorrect."
            echo "    Last retry message at line: $LAST_RETRY_LINE"
            echo "    First normal message at line: $FIRST_NORMAL_LINE"
        fi
    else
        echo "⚠️  WARNING: Not all messages were received."
    fi
fi

# Cleanup
echo ""
echo "Cleaning up..."
docker stop mqtt-order-subscriber 2>/dev/null || true
rm -f "${TEMP_FILE}"

echo ""
echo "✅ All MQTT tests completed!"
