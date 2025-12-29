#!/usr/bin/env python3
"""
Paho-mqtt publisher for testing.
Publishes a single message to a topic.
"""
import paho.mqtt.client as mqtt
from paho.mqtt.enums import MQTTProtocolVersion
import sys
import time
import logging

# Get configuration from command line
if len(sys.argv) != 5:
    print(f"Usage: {sys.argv[0]} <mqtt_host> <topic> <message> <qos>")
    sys.exit(1)

MQTT_HOST = sys.argv[1]
TOPIC = sys.argv[2]
MESSAGE = sys.argv[3]
QOS = int(sys.argv[4])
MQTT_PORT = 1883

# Enable debug logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

# Create MQTTv5 client
client = mqtt.Client(
    client_id=f"paho-pub-{MESSAGE}",
    protocol=MQTTProtocolVersion.MQTTv5
)

# Enable paho internal logging
client.enable_logger()

print(f"[PAHO-PUB] Connecting to {MQTT_HOST}:{MQTT_PORT}...")
sys.stdout.flush()

client.connect(MQTT_HOST, MQTT_PORT)
client.loop_start()

# Wait for connection
time.sleep(0.5)

print(f"[PAHO-PUB] Publishing: {MESSAGE} to {TOPIC} with QoS {QOS}")
sys.stdout.flush()

result = client.publish(TOPIC, MESSAGE, qos=QOS)
result.wait_for_publish()

print(f"[PAHO-PUB] Published successfully")
sys.stdout.flush()

time.sleep(0.1)
client.loop_stop()
client.disconnect()
