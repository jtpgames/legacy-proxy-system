import os
import sys
import signal
import logging
import json
from typing import Any, Optional
import paho.mqtt.client as mqtt
from paho.mqtt.enums import MQTTProtocolVersion, MQTTErrorCode
from paho.mqtt.properties import Properties
from paho.mqtt.reasoncodes import ReasonCode
import httpx
from httpx import HTTPStatusError, RequestError
from logging.handlers import RotatingFileHandler
import time
import socket
from urllib.parse import urlparse

# Configure logging
if not os.path.exists('logs'):
    os.makedirs('logs')

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

SERVICE_NAME = os.getenv("SERVICE_NAME", "legacy_proxy_2")
file_name = f'logs/{SERVICE_NAME}.log'
handler = RotatingFileHandler(
    file_name,
    maxBytes=100*1024*1024,  # 100MB
    backupCount=5
)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)

# Get configuration from environment variables
MQTT_HOST = os.getenv('MQTT_HOST', 'localhost')
MQTT_PORT = int(os.getenv('MQTT_PORT', '1883'))
MQTT_TOPIC = os.getenv('MQTT_TOPIC', '$share/legacy_proxy/+/message')
MQTT_RETRY_TOPIC_PUB = f'{SERVICE_NAME}/retry/message'
MQTT_RETRY_TOPIC_SUB = '$share/legacy_proxy/+/retry/message'
MQTT_QOS = int(os.getenv('MQTT_QOS', '2'))  # QoS level 2 by default
TARGET_URL = os.getenv('TARGET_URL', 'http://localhost:8080/ID_REQ_KC_STORE7D3BPACKET')

# DNS cache for hostname to IP resolution
dns_cache = {}

def resolve_hostname_to_ip(url: str) -> str:
    """Resolve hostname in URL to IP address, cache the result"""
    parsed = urlparse(url)
    hostname = parsed.hostname

    # Skip DNS caching if environment variable is set
    if os.getenv('SKIP_DNS_CACHE', '').lower() in ('1', 'true', 'yes'):
        return url
    
    if hostname in dns_cache:
        logger.debug(f"DNS cache hit for {hostname} -> {dns_cache[hostname]}")
        return url.replace(hostname, dns_cache[hostname])
    
    try:
        # Resolve hostname to IP
        ip_address = socket.gethostbyname(hostname)
        dns_cache[hostname] = ip_address
        logger.info(f"DNS resolved {hostname} -> {ip_address}")
        return url.replace(hostname, ip_address)
    except socket.gaierror as e:
        logger.warning(f"DNS resolution failed for {hostname}: {e}. Using original URL.")
        return url

# HTTP client will be initialized in MQTTToHTTPForwarder
httpclient: httpx.Client = None
resolved_target_url = ""

class MQTTToHTTPForwarder:
    def __init__(self):
        global httpclient, resolved_target_url
        
        # Resolve DNS and create HTTP client
        resolved_target_url = resolve_hostname_to_ip(TARGET_URL)
        
        use_http2 = os.getenv('USE_HTTP_2', '').lower() in ('1', 'true', 'yes')
        
        httpclient = httpx.Client(
            http2=use_http2,  # use http2 here because ARS_Comp_2 use HTTP2.
            http1=not use_http2,  # set to false to force http2 over plain text. Disabling http1 here, deactivates HTTP 1.1 Upgrade to HTTP 2.0
            timeout=httpx.Timeout(60.0),  # 60 second timeout
            limits=httpx.Limits(
                max_keepalive_connections=100,
                max_connections=None,  # No limit
                keepalive_expiry=30.0
            )
        )
        logger.info(f"HTTP client initialized with resolved URL: {resolved_target_url}, HTTP/2: {use_http2}")
        
        self.client = mqtt.Client(
                client_id=os.getenv("SERVICE_NAME", "legacy_proxy_2"), 
                manual_ack=True,        # manually acknowledge successful message reception to allow rejecting a message in case of a downstream error.
                protocol=MQTTProtocolVersion.MQTTv5
                )
        self.client.on_connect = self.on_connect
        self.client.on_subscribe = self.on_subscribe
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect
        self.client.enable_logger(logger)
        self.running = False
        self.is_in_retry_mode = False

    def on_connect(self, client: mqtt.Client, userdata: Any, flags: dict, rc: ReasonCode, properties: Optional[Properties]) -> None:
        """Callback for when the client connects to the broker."""
        if rc == 0:
            logger.info(f"Connected to MQTT broker at {MQTT_HOST}:{MQTT_PORT}")
            logger.info(f"CONNECT response: rc={rc}, flags={flags}")
            result, mid = self.client.subscribe(MQTT_TOPIC, qos=MQTT_QOS)
            logger.info(f"Subscribed to topic: {MQTT_TOPIC} with QoS {MQTT_QOS}, result: {result}, mid: {mid}")
            result_retry, mid_retry = self.client.subscribe(MQTT_RETRY_TOPIC_SUB, qos=MQTT_QOS)
            logger.info(f"Subscribed to topic: {MQTT_RETRY_TOPIC_SUB} with QoS {MQTT_QOS}, result: {result_retry}, mid: {mid_retry}")
        else:
            logger.error(f"Failed to connect to MQTT broker with code: {rc}")

    def on_subscribe(self, client: mqtt.Client, userdata: Any, mid: int, reason_codes: list[ReasonCode], properties: Optional[Properties]) -> None:
        """Callback for when the broker responds to a subscribe request."""
        logger.info(f"SUBACK received for mid {mid}, reason_codes: {[str(rc) for rc in reason_codes]}")
        for i, rc in enumerate(reason_codes):
            if rc.is_failure:
                logger.error(f"Subscription {i} failed with reason code: {rc}")
            else:
                logger.info(f"Subscription {i} granted with QoS: {rc}")

    def on_message(self, client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
        """Callback for when a message is received from the broker."""

        request_id = "N/A"
        try:
            payload = msg.payload.decode()
            json_payload = json.loads(payload)
            request_id = json_payload["request_id"]
            logger.info(f"[{request_id}] Received message {msg.mid} on topic {msg.topic} (QoS {msg.qos}, DUP {msg.dup}): {payload}")

            headers = {"Request-Id": f"{request_id}"}
            response = httpclient.post(resolved_target_url, headers=headers, json=json_payload)
            logger.debug(f"[{request_id}] HTTP version: {response.http_version}")
            response.raise_for_status()
            logger.info(f"[{request_id}] Successfully forwarded message to {resolved_target_url}")
            
            if self.is_in_retry_mode:
                # self.client.subscribe(MQTT_TOPIC, qos=MQTT_QOS)
                # logger.info(f"Subscribed to topic: {MQTT_TOPIC} with QoS {MQTT_QOS}")
                self.is_in_retry_mode = False

        except json.JSONDecodeError as e:
            logger.error(f"[{request_id}] Failed to decode message as JSON: {e}")
        except (HTTPStatusError, RequestError) as e:
            logger.error(f"[{request_id}] Failed to forward message to HTTP endpoint: {e}")
            message = msg.payload
            (rc, mid) = client.publish(
                topic=MQTT_RETRY_TOPIC_PUB,
                payload=message,
                qos=msg.qos
            )
            if rc == MQTTErrorCode.MQTT_ERR_SUCCESS:
                if not self.is_in_retry_mode:
                    # client.unsubscribe(MQTT_TOPIC)
                    self.is_in_retry_mode = True
                time.sleep(1) # wait one second before sending ack to slow down this consumer in case the reason for the failure is not a short error.
        except Exception as e:
            logger.error(f"[{request_id}] Unexpected error while processing message: {e}")
        finally:
            # An ack is send by the library automatically once this method returns and manual_ack is set to False. We send the ACK explicitly to allow changing the value of manual_ack without having to change the rest of the code for it to work.
            logger.info(f"[{request_id}] Sending Ack for {msg.mid} with QoS {msg.qos}")
            client.ack(msg.mid, qos=msg.qos)

    def on_disconnect(self, client: mqtt.Client, userdata: Any, flags: mqtt.DisconnectFlags, rc: ReasonCode) -> None:
        """Callback for when the client disconnects from the broker."""
        if rc != 0:
            logger.warning("Unexpected disconnection from MQTT broker")

    def start(self) -> None:
        """Start the MQTT client and connect to the broker."""
        try:
            self.client.connect(
                    MQTT_HOST, 
                    MQTT_PORT, 
                    clean_start=False       # do not discard in-flight messages
                    )
            self.running = True
            self.client.loop_start()
        except Exception as e:
            logger.error(f"Failed to start MQTT client: {e}")
            sys.exit(1)

    def stop(self) -> None:
        """Stop the MQTT client and disconnect from the broker."""
        global httpclient
        self.running = False
        self.client.loop_stop()
        self.client.disconnect()
        logger.info("MQTT client stopped")
        if httpclient:
            httpclient.close()
            logger.info("HTTP client closed")

    def reconnect(self) -> None:
        """Stop (disconnect) and start (connect) the MQTT client."""
        self.stop()
        self.start()

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

