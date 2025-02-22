import os
import sys
import signal
import logging
import json
from typing import Any
import paho.mqtt.client as mqtt
import requests
from logging.handlers import RotatingFileHandler
from requests.exceptions import RequestException

# Configure logging
if not os.path.exists('logs'):
    os.makedirs('logs')

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

file_name = f'logs/{os.getenv("SERVICE_NAME", "legacy_proxy_2")}.log'
handler = RotatingFileHandler(
    file_name,
    maxBytes=10*1024*1024,  # 10MB
    backupCount=5
)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)

# Get configuration from environment variables
MQTT_HOST = os.getenv('MQTT_HOST', 'localhost')
MQTT_PORT = int(os.getenv('MQTT_PORT', '1883'))
MQTT_TOPIC = os.getenv('MQTT_TOPIC', '$share/legacy_proxy/+/message')
MQTT_QOS = int(os.getenv('MQTT_QOS', '2'))  # QoS level 2 by default
TARGET_URL = os.getenv('TARGET_URL', 'http://localhost:8080/ID_REQ_KC_STORE7D3BPACKET')

class MQTTToHTTPForwarder:
    def __init__(self):
        self.client = mqtt.Client()
        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect
        self.running = True

    def on_connect(self, client: mqtt.Client, userdata: Any, flags: dict, rc: int) -> None:
        """Callback for when the client connects to the broker."""
        if rc == 0:
            logger.info(f"Connected to MQTT broker at {MQTT_HOST}:{MQTT_PORT}")
            self.client.subscribe(MQTT_TOPIC, qos=MQTT_QOS)
            logger.info(f"Subscribed to topic: {MQTT_TOPIC} with QoS {MQTT_QOS}")
        else:
            logger.error(f"Failed to connect to MQTT broker with code: {rc}")

    def on_message(self, client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
        """Callback for when a message is received from the broker."""
        try:
            payload = msg.payload.decode()
            logger.info(f"Received message on topic {msg.topic} (QoS {msg.qos}): {payload}")
            
            response = requests.post(TARGET_URL, json=payload)
            response.raise_for_status()
            logger.info(f"Successfully forwarded message to {TARGET_URL}")
            
        except json.JSONDecodeError as e:
            logger.error(f"Failed to decode message as JSON: {e}")
        except RequestException as e:
            logger.error(f"Failed to forward message to HTTP endpoint: {e}")
        except Exception as e:
            logger.error(f"Unexpected error while processing message: {e}")

    def on_disconnect(self, client: mqtt.Client, userdata: Any, rc: int) -> None:
        """Callback for when the client disconnects from the broker."""
        if rc != 0:
            logger.warning("Unexpected disconnection from MQTT broker")

    def start(self) -> None:
        """Start the MQTT client and connect to the broker."""
        try:
            self.client.connect(MQTT_HOST, MQTT_PORT)
            self.client.loop_start()
        except Exception as e:
            logger.error(f"Failed to start MQTT client: {e}")
            sys.exit(1)

    def stop(self) -> None:
        """Stop the MQTT client and disconnect from the broker."""
        self.running = False
        self.client.loop_stop()
        self.client.disconnect()
        logger.info("MQTT client stopped")

def signal_handler(signum: int, frame: Any) -> None:
    """Handle shutdown signals."""
    logger.info("Shutdown signal received")
    forwarder.stop()
    sys.exit(0)

if __name__ == "__main__":
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Create and start the forwarder
    forwarder = MQTTToHTTPForwarder()
    logger.info("Starting MQTT to HTTP forwarder")
    forwarder.start()

    # Keep the main thread running
    while forwarder.running:
        signal.pause()

