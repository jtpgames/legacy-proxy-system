#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_DIR="${SCRIPT_DIR}/../python"
COMPOSE_FILE="docker-compose-ng-hivemq.yml"
HIVEMQ_HOST="hivemq"
MQTT_PORT="1883"

# Parse command line arguments
CLIENT_TYPE="mosquitto"  # Default to mosquitto_sub
PUBLISHER_TYPE="mosquitto"  # Default to mosquitto_pub
MQTT_QOS=1  # Default to QoS 1

while [[ $# -gt 0 ]]; do
    case $1 in
        --paho|-p)
            CLIENT_TYPE="paho"
            shift
            ;;
        --paho-pub)
            PUBLISHER_TYPE="paho"
            shift
            ;;
        --aiomqtt-pub)
            PUBLISHER_TYPE="aiomqtt"
            shift
            ;;
        --aiomqtt-persistent)
            PUBLISHER_TYPE="aiomqtt-persistent"
            shift
            ;;
        --qos)
            MQTT_QOS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--paho|-p] [--paho-pub] [--aiomqtt-pub] [--aiomqtt-persistent] [--qos <1|2>]"
            echo "  --paho/-p: Use paho-mqtt for subscribers (default: mosquitto_sub)"
            echo "  --paho-pub: Use paho-mqtt for publisher (default: mosquitto_pub)"
            echo "  --aiomqtt-pub: Use aiomqtt for publisher with new connection per message (default: mosquitto_pub)"
            echo "  --aiomqtt-persistent: Use aiomqtt with persistent connection (matching proxy1)"
            echo "  --qos: QoS level for MQTT messages (default: 1)"
            exit 1
            ;;
    esac
done

echo "Subscriber: ${CLIENT_TYPE}"
echo "Publisher: ${PUBLISHER_TYPE}"
echo "QoS: ${MQTT_QOS}"

# Create timestamped log directory for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_NAME="${CLIENT_TYPE}_sub-${PUBLISHER_TYPE}_pub-qos${MQTT_QOS}"
LOG_DIR="${SCRIPT_DIR}/test_logs/${TIMESTAMP}_${TEST_NAME}"
mkdir -p "${LOG_DIR}"

echo "=========================================="
echo "HiveMQ Shared Subscription Load Balancing Test"
echo "=========================================="
echo "Test run: ${TEST_NAME}"
echo "Logs will be saved to: ${LOG_DIR}"
echo ""

# Clean up any existing containers and volumes
echo "Cleaning up existing containers and volumes..."
cd "${PYTHON_DIR}"
docker ps -a | grep subscriber | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null || true
docker-compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
docker volume rm python_hivemq-data 2>/dev/null || true
killall -9 "docker logs" 2>/dev/null || true

# Start only HiveMQ service
echo "Starting HiveMQ broker..."
docker-compose -f "${COMPOSE_FILE}" up -d hivemq

# Wait for HiveMQ to be ready
echo "Waiting for HiveMQ to start..."
sleep 10

# Get network name
NETWORK_NAME=$(docker inspect $(docker-compose -f "${COMPOSE_FILE}" ps -q hivemq) --format='{{range $net,$v := .NetworkSettings.Networks}}{{$net}}{{end}}')
echo "Network: ${NETWORK_NAME}"
echo ""

# Test parameters - matching real NG experiment setup
SHARED_TOPIC="\$share/legacy_proxy/+/message"  # Matching proxy2 config
NUM_MESSAGES=300  # Increased from 30 to test at scale
CLIENT_TIMEOUT=15

# Publishers publish to individual topics that match the wildcard
# Matching proxy1-1, proxy1-2, proxy1-3 topics
PUBLISH_TOPICS=("proxy1/message" "proxy2/message" "proxy3/message")

echo "=== Test Configuration ==="
echo "Publish topics: ${PUBLISH_TOPICS[@]}"
echo "Shared subscription: ${SHARED_TOPIC}"
echo "Number of messages: ${NUM_MESSAGES}"
echo "3 publishers -> 3 subscribers (shared subscription load balancing)"
echo "Expected: ~${NUM_MESSAGES}/3 messages per subscriber"
echo ""

# Start 3 subscribers with shared subscription
if [ "${CLIENT_TYPE}" == "mosquitto" ]; then
    echo "=== Starting 3 Mosquitto Subscribers ==="
    
    for i in 1 2 3; do
        CLIENT_ID="subscriber-${i}"
        LOG_FILE="${LOG_DIR}/mosquitto_${CLIENT_ID}.log"
        echo "Starting ${CLIENT_ID} with clean_start=False (using -c flag)..."
        
        # Start subscriber and immediately start logging its output
        docker run --rm -d \
            --name "${CLIENT_ID}" \
            --network "${NETWORK_NAME}" \
            eclipse-mosquitto:latest \
            mosquitto_sub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" \
            -i "${CLIENT_ID}" \
            -c \
            -t "${SHARED_TOPIC}" \
            -q ${MQTT_QOS} \
            -V 5 \
            -d \
            -v
        
        sleep 1
    done
elif [ "${CLIENT_TYPE}" == "paho" ]; then
    echo "=== Starting 3 Paho-MQTT Python Subscribers ==="
    
    for i in 1 2 3; do
        CLIENT_ID="subscriber-${i}"
        LOG_FILE="${LOG_DIR}/paho_${CLIENT_ID}.log"
        echo "Starting ${CLIENT_ID} with clean_start=False..."
        
        # Start paho subscriber in Docker container
        docker run --rm -d \
            --name "${CLIENT_ID}" \
            --network "${NETWORK_NAME}" \
            -v "${SCRIPT_DIR}/paho_subscriber.py:/paho_subscriber.py" \
            python:3.12-slim \
            bash -c "pip install -q paho-mqtt && python /paho_subscriber.py ${HIVEMQ_HOST} ${CLIENT_ID} '${SHARED_TOPIC}' ${MQTT_QOS}"
        
        sleep 1
    done
fi

echo ""
echo "All subscribers connected. Waiting 3 seconds for subscriptions to settle..."
sleep 3

# Publish messages from multiple concurrent publishers
echo ""
if [ "${PUBLISHER_TYPE}" == "aiomqtt-persistent" ]; then
    echo "=== Publishing ${NUM_MESSAGES} Messages (3 persistent aiomqtt publishers) ==="
else
    echo "=== Publishing ${NUM_MESSAGES} Messages (3 concurrent publishers, no delay) ==="
fi

# Split messages across 3 publishers
MSGS_PER_PUBLISHER=$((NUM_MESSAGES / 3))

# Start 3 publishers in parallel - each publishes to its own topic
if [ "${PUBLISHER_TYPE}" == "aiomqtt-persistent" ]; then
    # Use persistent aiomqtt connection (matching proxy1 behavior exactly)
    for pub_id in 1 2 3; do
        TOPIC="${PUBLISH_TOPICS[$((pub_id - 1))]}"
        CLIENT_ID="proxy1-${pub_id}"
        MESSAGE_PREFIX="P${pub_id}"
        
        echo "Starting persistent publisher ${pub_id} (${CLIENT_ID} -> ${TOPIC})..."
        
        docker run --rm -d \
            --name "publisher-${pub_id}" \
            --network "${NETWORK_NAME}" \
            -v "${SCRIPT_DIR}/aiomqtt_persistent_publisher.py:/aiomqtt_persistent_publisher.py" \
            python:3.12-slim \
            bash -c "pip install -q aiomqtt && python /aiomqtt_persistent_publisher.py ${HIVEMQ_HOST} ${CLIENT_ID} ${TOPIC} ${MESSAGE_PREFIX} ${MSGS_PER_PUBLISHER} ${MQTT_QOS}" &
        
        sleep 0.5
    done
    
    # Wait for all publishers to complete
    echo "Waiting for persistent publishers to complete..."
    sleep 15
    
    # Collect publisher logs
    for pub_id in 1 2 3; do
        echo "Publisher ${pub_id} output:"
        docker logs "publisher-${pub_id}" 2>&1 | grep -E "\[proxy1-${pub_id}\]" | tail -5
        docker stop "publisher-${pub_id}" 2>/dev/null || true
    done
else
    # Original behavior: new connection per message
    for pub_id in 1 2 3; do
        (
            start=$((($pub_id - 1) * MSGS_PER_PUBLISHER + 1))
            end=$(($pub_id * MSGS_PER_PUBLISHER))
            
            # Get topic for this publisher (matching proxy1-1, proxy1-2, proxy1-3)
            TOPIC="${PUBLISH_TOPICS[$((pub_id - 1))]}"
            
            if [ "${PUBLISHER_TYPE}" == "paho" ]; then
                # Use paho-mqtt publisher
                for i in $(seq $start $end); do
                    docker run --rm \
                        --network "${NETWORK_NAME}" \
                        -v "${SCRIPT_DIR}/paho_publisher.py:/paho_publisher.py" \
                        python:3.12-slim \
                        bash -c "pip install -q paho-mqtt && python /paho_publisher.py ${HIVEMQ_HOST} ${TOPIC} 'Message-${i}' ${MQTT_QOS}" &>/dev/null
                    echo "  Publisher ${pub_id} (${TOPIC}): Message-${i}"
                done
            elif [ "${PUBLISHER_TYPE}" == "aiomqtt" ]; then
                # Use aiomqtt publisher (new connection per message)
                for i in $(seq $start $end); do
                    docker run --rm \
                        --network "${NETWORK_NAME}" \
                        -v "${SCRIPT_DIR}/aiomqtt_publisher.py:/aiomqtt_publisher.py" \
                        python:3.12-slim \
                        bash -c "pip install -q aiomqtt && python /aiomqtt_publisher.py ${HIVEMQ_HOST} ${TOPIC} 'Message-${i}' ${MQTT_QOS}" &>/dev/null
                    echo "  Publisher ${pub_id} (${TOPIC}): Message-${i}"
                done
            else
                # Use mosquitto_pub
                for i in $(seq $start $end); do
                    docker run --rm \
                        --network "${NETWORK_NAME}" \
                        eclipse-mosquitto:latest \
                        mosquitto_pub -h "${HIVEMQ_HOST}" -p "${MQTT_PORT}" \
                        -t "${TOPIC}" \
                        -m "Message-${i}" \
                        -q ${MQTT_QOS} \
                        -V 5 &>/dev/null
                    echo "  Publisher ${pub_id} (${TOPIC}): Message-${i}"
                done
            fi
        ) &
    done
    
    # Wait for all publishers to complete
    wait
    echo "All publishers completed"
fi

echo ""
echo "All messages published. Waiting ${CLIENT_TIMEOUT} seconds for delivery..."
sleep ${CLIENT_TIMEOUT}

# Save logs to files
echo "Saving logs to files..."
for i in 1 2 3; do
    CLIENT_ID="subscriber-${i}"
    if [ "${CLIENT_TYPE}" == "paho" ]; then
        LOG_FILE="${LOG_DIR}/paho_${CLIENT_ID}.log"
    else
        LOG_FILE="${LOG_DIR}/mosquitto_${CLIENT_ID}.log"
    fi
    docker logs "${CLIENT_ID}" > "${LOG_FILE}" 2>&1
done

# Collect and analyze results
echo ""
echo "=== Results ==="
echo ""

TOTAL_RECEIVED=0
for i in 1 2 3; do
    CLIENT_ID="subscriber-${i}"
    
    # Count messages - handle different message patterns
    if [ "${CLIENT_TYPE}" == "paho" ]; then
        # Paho logs: "RECEIVED:" prefix, messages can be "Message-X" or "PX-Y"
        MESSAGE_COUNT=$(docker logs "${CLIENT_ID}" 2>&1 | grep -c "RECEIVED:.*\(Message-\|P[123]-\)" || echo "0")
    else
        # Mosquitto logs: messages can be "Message-X" or "PX-Y"
        MESSAGE_COUNT=$(docker logs "${CLIENT_ID}" 2>&1 | grep -E -c "(Message-|P[123]-)" || echo "0")
    fi
    TOTAL_RECEIVED=$((TOTAL_RECEIVED + MESSAGE_COUNT))
    
    echo "${CLIENT_ID}: received ${MESSAGE_COUNT} messages"
    
    # Show first few messages for debugging
    if [ "${MESSAGE_COUNT}" -gt 0 ]; then
        echo "  First 3 messages:"
        if [ "${CLIENT_TYPE}" == "paho" ]; then
            docker logs "${CLIENT_ID}" 2>&1 | grep -E "RECEIVED:.*(Message-|P[123]-)" | head -3 | sed 's/^/    /'
        else
            docker logs "${CLIENT_ID}" 2>&1 | grep -E "(Message-|P[123]-)" | head -3 | sed 's/^/    /'
        fi
    fi
    echo ""
done

# Analysis
echo "=== Analysis ==="
echo "Total messages published: ${NUM_MESSAGES}"
echo "Total messages received: ${TOTAL_RECEIVED}"
echo ""

if [ "${TOTAL_RECEIVED}" -eq "${NUM_MESSAGES}" ]; then
    echo "✅ All messages received"
else
    echo "❌ Message count mismatch! Expected ${NUM_MESSAGES}, got ${TOTAL_RECEIVED}"
fi

# Check load balancing
if [ "${CLIENT_TYPE}" == "paho" ]; then
    SUB1_COUNT=$(docker logs subscriber-1 2>&1 | grep -c "RECEIVED:.*\(Message-\|P[123]-\)" || echo "0")
    SUB2_COUNT=$(docker logs subscriber-2 2>&1 | grep -c "RECEIVED:.*\(Message-\|P[123]-\)" || echo "0")
    SUB3_COUNT=$(docker logs subscriber-3 2>&1 | grep -c "RECEIVED:.*\(Message-\|P[123]-\)" || echo "0")
else
    SUB1_COUNT=$(docker logs subscriber-1 2>&1 | grep -E -c "(Message-|P[123]-)" || echo "0")
    SUB2_COUNT=$(docker logs subscriber-2 2>&1 | grep -E -c "(Message-|P[123]-)" || echo "0")
    SUB3_COUNT=$(docker logs subscriber-3 2>&1 | grep -E -c "(Message-|P[123]-)" || echo "0")
fi

MAX_COUNT=$(echo -e "${SUB1_COUNT}\n${SUB2_COUNT}\n${SUB3_COUNT}" | sort -rn | head -1)
MIN_COUNT=$(echo -e "${SUB1_COUNT}\n${SUB2_COUNT}\n${SUB3_COUNT}" | sort -n | head -1)

echo ""
echo "Distribution:"
echo "  Max: ${MAX_COUNT} messages"
echo "  Min: ${MIN_COUNT} messages"
echo "  Difference: $((MAX_COUNT - MIN_COUNT))"
echo ""

# Check if one subscriber got all messages (broken behavior)
if [ "${MAX_COUNT}" -eq "${NUM_MESSAGES}" ] && [ "${MIN_COUNT}" -eq 0 ]; then
    echo "❌ LOAD BALANCING BROKEN: One subscriber received all messages!"
    echo "   This indicates HiveMQ shared subscription bug."
elif [ "$((MAX_COUNT - MIN_COUNT))" -le 3 ]; then
    echo "✅ LOAD BALANCING WORKING: Messages distributed evenly"
else
    echo "⚠️  LOAD BALANCING SUBOPTIMAL: Uneven distribution"
fi

# Cleanup
echo ""
echo "=== Cleanup ==="

for i in 1 2 3; do
    docker stop "subscriber-${i}" 2>/dev/null || true
done

cd "${PYTHON_DIR}"
docker-compose -f "${COMPOSE_FILE}" down -v

# Create test summary
SUMMARY_FILE="${LOG_DIR}/test_summary.txt"
cat > "${SUMMARY_FILE}" << EOF
=========================================
HiveMQ Shared Subscription Load Balancing Test
=========================================
Test Name: ${TEST_NAME}
Timestamp: ${TIMESTAMP}
Subscriber: ${CLIENT_TYPE}
Publisher: ${PUBLISHER_TYPE}
QoS: ${MQTT_QOS}

=== Configuration ===
Publish topics: ${PUBLISH_TOPICS[@]}
Shared subscription: ${SHARED_TOPIC}
Number of messages: ${NUM_MESSAGES}
Topology: 3 publishers -> MQTT broker -> 3 subscribers (shared subscription)

=== Results ===
Total messages published: ${NUM_MESSAGES}
Total messages received: ${TOTAL_RECEIVED}

Distribution:
  subscriber-1: ${SUB1_COUNT} messages
  subscriber-2: ${SUB2_COUNT} messages
  subscriber-3: ${SUB3_COUNT} messages
  
  Max: ${MAX_COUNT} messages
  Min: ${MIN_COUNT} messages
  Difference: $((MAX_COUNT - MIN_COUNT))

Load Balancing Status:
EOF

if [ "${MAX_COUNT}" -eq "${NUM_MESSAGES}" ] && [ "${MIN_COUNT}" -eq 0 ]; then
    echo "❌ BROKEN: One subscriber received all messages!" >> "${SUMMARY_FILE}"
elif [ "$((MAX_COUNT - MIN_COUNT))" -le 3 ]; then
    echo "✅ WORKING: Messages distributed evenly" >> "${SUMMARY_FILE}"
else
    echo "⚠️  SUBOPTIMAL: Uneven distribution" >> "${SUMMARY_FILE}"
fi

echo "" >> "${SUMMARY_FILE}"
echo "=== Files ===" >> "${SUMMARY_FILE}"
echo "Subscriber logs:" >> "${SUMMARY_FILE}"
ls -1 "${LOG_DIR}"/*.log 2>/dev/null | sed 's/^/  /' >> "${SUMMARY_FILE}"

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
echo "Test Name: ${TEST_NAME}"
echo "All logs saved to: ${LOG_DIR}"
echo "Summary: ${SUMMARY_FILE}"
echo ""

# Display summary
cat "${SUMMARY_FILE}"
