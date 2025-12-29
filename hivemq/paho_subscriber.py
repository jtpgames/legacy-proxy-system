#!/usr/bin/env python3
"""
Single paho-mqtt subscriber for use in shell test script.
Logs to stdout for docker logs capture.
"""
import paho.mqtt.client as mqtt
from paho.mqtt.enums import MQTTProtocolVersion
from paho.mqtt.packettypes import PacketTypes
import sys
import logging

# Get configuration from command line
if len(sys.argv) < 4:
    print(f"Usage: {sys.argv[0]} <mqtt_host> <client_id> <shared_topic> [qos]")
    sys.exit(1)

MQTT_HOST = sys.argv[1]
CLIENT_ID = sys.argv[2]
SHARED_TOPIC = sys.argv[3]
SUBSCRIBE_QOS = int(sys.argv[4]) if len(sys.argv) > 4 else 1  # Default to QoS 1
MQTT_PORT = 1883

# Enable debug logging to see CONNECT/SUBSCRIBE packets
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)


def on_connect(client, userdata, flags, rc, properties=None):
    """Connection callback"""
    print(f"[{CLIENT_ID}] CONNECT response: rc={rc}, flags={flags}")
    if rc == 0:
        print(f"[{CLIENT_ID}] Connected successfully")
        client.subscribe(SHARED_TOPIC, qos=SUBSCRIBE_QOS)
        print(f"[{CLIENT_ID}] SUBSCRIBE sent for {SHARED_TOPIC} with QoS {SUBSCRIBE_QOS}")
    else:
        print(f"[{CLIENT_ID}] Connection failed with code {rc}")
        sys.exit(1)


def on_subscribe(client, userdata, mid, reason_codes, properties=None):
    """Subscribe callback"""
    print(f"[{CLIENT_ID}] SUBACK received, mid={mid}, reason_codes={reason_codes}")


def on_message(client, userdata, msg):
    """Message received callback"""
    print(f"[{CLIENT_ID}] RECEIVED: {msg.topic} {msg.payload.decode()}")
    sys.stdout.flush()


# Create MQTTv5 client with clean_start=False (matching mosquitto_sub -c)
client = mqtt.Client(
    client_id=CLIENT_ID,
    protocol=MQTTProtocolVersion.MQTTv5
)

# Enable paho internal logging
client.enable_logger()

client.on_connect = on_connect
client.on_subscribe = on_subscribe
client.on_message = on_message

print(f"[{CLIENT_ID}] Connecting to {MQTT_HOST}:{MQTT_PORT}...")
print(f"[{CLIENT_ID}] Using MQTTv5, clean_start=False, session_expiry=0 (default), QoS={SUBSCRIBE_QOS}")
sys.stdout.flush()

client.connect(
    MQTT_HOST,
    MQTT_PORT,
    clean_start=False
    # No properties = session expiry interval defaults to 0
)

# Block forever, processing network loop
print(f"[{CLIENT_ID}] Starting network loop...")
sys.stdout.flush()
client.loop_forever()
