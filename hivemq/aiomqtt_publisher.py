#!/usr/bin/env python3
"""
Aiomqtt publisher for testing.
Publishes a single message to a topic (matching proxy1 implementation).
"""
import aiomqtt
import sys
import asyncio
import logging

# Get configuration from command line
if len(sys.argv) < 4:
    print(f"Usage: {sys.argv[0]} <mqtt_host> <topic> <message> [qos]")
    sys.exit(1)

MQTT_HOST = sys.argv[1]
TOPIC = sys.argv[2]
MESSAGE = sys.argv[3]
QOS = int(sys.argv[4]) if len(sys.argv) > 4 else 2  # Default to QoS 2 (matching proxy1)
MQTT_PORT = 1883

# Enable debug logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

async def publish():
    """Publish a message using aiomqtt (matching proxy1 config)"""
    print(f"[AIOMQTT-PUB] Connecting to {MQTT_HOST}:{MQTT_PORT}...")
    print(f"[AIOMQTT-PUB] Using MQTTv5, clean_start=False, QoS={QOS}")
    sys.stdout.flush()
    
    async with aiomqtt.Client(
        hostname=MQTT_HOST,
        port=MQTT_PORT,
        identifier=f"aiomqtt-pub-{MESSAGE}",
        clean_start=False,  # Matching proxy1
        protocol=aiomqtt.ProtocolVersion.V5
    ) as client:
        print(f"[AIOMQTT-PUB] Connected successfully")
        print(f"[AIOMQTT-PUB] Publishing: {MESSAGE} to {TOPIC} with QoS {QOS}")
        sys.stdout.flush()
        
        await client.publish(
            topic=TOPIC,
            payload=MESSAGE,
            qos=QOS,
            retain=False
        )
        
        print(f"[AIOMQTT-PUB] Published successfully")
        sys.stdout.flush()

if __name__ == "__main__":
    asyncio.run(publish())
