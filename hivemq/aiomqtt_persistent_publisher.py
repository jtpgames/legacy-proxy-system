#!/usr/bin/env python3
"""
Persistent aiomqtt publisher that mimics proxy1 behavior.
Maintains a single persistent connection and publishes multiple messages to one topic.
"""
import aiomqtt
import sys
import asyncio
import logging

# Get configuration from command line
if len(sys.argv) < 6:
    print(f"Usage: {sys.argv[0]} <mqtt_host> <client_id> <topic> <message_prefix> <num_messages> [qos]")
    sys.exit(1)

MQTT_HOST = sys.argv[1]
CLIENT_ID = sys.argv[2]
TOPIC = sys.argv[3]
MESSAGE_PREFIX = sys.argv[4]
NUM_MESSAGES = int(sys.argv[5])
QOS = int(sys.argv[6]) if len(sys.argv) > 6 else 2
MQTT_PORT = 1883

# Enable debug logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

async def publish_messages():
    """
    Publish messages using persistent aiomqtt connection (matching proxy1 config).
    This mimics how proxy1 maintains a single connection and publishes many messages.
    """
    print(f"[{CLIENT_ID}] Connecting to {MQTT_HOST}:{MQTT_PORT}...")
    print(f"[{CLIENT_ID}] Using MQTTv5, clean_start=False, QoS={QOS}")
    print(f"[{CLIENT_ID}] Will publish {NUM_MESSAGES} messages to {TOPIC} with prefix '{MESSAGE_PREFIX}'")
    sys.stdout.flush()
    
    # Create persistent connection matching proxy1 configuration
    async with aiomqtt.Client(
        hostname=MQTT_HOST,
        port=MQTT_PORT,
        identifier=CLIENT_ID,
        clean_start=False,  # Persistent session - matching proxy1
        protocol=aiomqtt.ProtocolVersion.V5
    ) as client:
        print(f"[{CLIENT_ID}] Connected successfully")
        sys.stdout.flush()
        
        # Publish all messages rapidly without delay
        for i in range(1, NUM_MESSAGES + 1):
            message = f"{MESSAGE_PREFIX}-{i}"
            
            await client.publish(
                topic=TOPIC,
                payload=message,
                qos=QOS,
                retain=False
            )
            
            if i % 10 == 0:
                print(f"[{CLIENT_ID}] Published {i}/{NUM_MESSAGES} messages")
                sys.stdout.flush()
        
        print(f"[{CLIENT_ID}] All {NUM_MESSAGES} messages published successfully")
        sys.stdout.flush()

if __name__ == "__main__":
    asyncio.run(publish_messages())
