from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import aiomqtt
import logging
from logging.handlers import RotatingFileHandler
import os
import json
from typing import Tuple, Optional
import uvicorn
from contextlib import asynccontextmanager

# Configure logging
if not os.path.exists('logs'):
    os.makedirs('logs')

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

uvicorn_logger = logging.getLogger("uvicorn")
uvicorn_logger.setLevel(logging.INFO)

file_name = f'logs/{os.getenv("SERVICE_NAME", "legacy_proxy_1")}.log'
handler = RotatingFileHandler(
    file_name,
    maxBytes=100*1024*1024,  # 100MB
    backupCount=5
)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

logger.addHandler(handler)
uvicorn_logger.addHandler(handler)

# Get configuration from environment variables with defaults
MQTT_BROKER = os.getenv('MQTT_BROKER', 'localhost')
MQTT_PORT = int(os.getenv('MQTT_PORT', '1883'))
MQTT_TOPIC = os.getenv('MQTT_TOPIC', 'default/topic')
CLIENT_ID = os.getenv("SERVICE_NAME", "legacy_proxy_1")

# Global MQTT client instance
mqtt_client: Optional[aiomqtt.Client] = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage MQTT client lifecycle."""
    global mqtt_client
    
    # Startup: Create persistent MQTT connection
    logger.info(f"Connecting to MQTT broker at {MQTT_BROKER}:{MQTT_PORT} using MQTT5")
    mqtt_client = aiomqtt.Client(
        hostname=MQTT_BROKER,
        port=MQTT_PORT,
        identifier=CLIENT_ID,
        clean_start=False,  # Persistent session for MQTT5
        protocol=aiomqtt.ProtocolVersion.V5
    )
    
    try:
        await mqtt_client.__aenter__()
        logger.info("Successfully connected to MQTT broker")
        yield
    finally:
        # Shutdown: Close MQTT connection
        if mqtt_client:
            logger.info("Closing MQTT connection")
            await mqtt_client.__aexit__(None, None, None)
            mqtt_client = None

# Initialize FastAPI app with lifespan
app = FastAPI(
    title="Legacy Proxy I",
    description="HTTP to MQTT bridge service",
    lifespan=lifespan
)

class Message(BaseModel):
    """Pydantic model for request validation"""
    id: str
    body: str

async def publish_to_mqtt(message: str) -> Tuple[bool, str]:
    """
    Asynchronously publish a message to MQTT broker with QoS 2.
    
    Returns:
        Tuple[bool, str]: Success status and error message if any
    """
    if mqtt_client is None:
        error_msg = "MQTT client not initialized"
        logger.error(error_msg)
        return False, error_msg
    
    try:
        await mqtt_client.publish(
            topic=MQTT_TOPIC,
            payload=message,
            qos=2,
            retain=False
        )
        return True, ""
    except aiomqtt.MqttError as e:
        error_msg = f"MQTT Error: {str(e)}"
        logger.error(error_msg)
        return False, error_msg
    except Exception as e:
        error_msg = f"Unexpected error while publishing: {str(e)}"
        logger.error(error_msg)
        return False, error_msg

@app.post("/ID_REQ_KC_STORE7D3BPACKET")
async def receive_message(message: Message, request_id: Optional[str] = Header(default=None)):
    """Handle incoming POST requests with JSON data."""
    try:
        # Convert message to JSON string
        message_dict = {"id": message.id, "body": message.body}
        if request_id is not None:
            message_dict["request_id"] = request_id
        message_str = json.dumps(message_dict)
       
        logger.info(f"[{request_id}] Publishing message {message_str} to Broker ...")
        # Publish to MQTT
        success, error = await publish_to_mqtt(message_str)
        
        if not success:
            logger.error(f"[{request_id}] MQTT publish failed: {error}")
            raise HTTPException(
                status_code=500,
                detail=f"Failed to publish message: {error}"
            )

        logger.info(f"[{request_id}] Successfully published message")
        return {
            "status": "success",
            "message": "Data published to MQTT"
        }

    except Exception as e:
        logger.error(f"[{request_id}] Error processing request: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Internal server error: {str(e)}"
        )

if __name__ == '__main__':
    port = int(os.getenv('HTTP_PORT', '8080'))
    host = os.getenv('HTTP_HOST', '0.0.0.0')
    
    logger.info(f"Starting server on {host}:{port}")
    logger.info(f"MQTT broker configured at {MQTT_BROKER}:{MQTT_PORT}")
    logger.info(f"Publishing to topic: {MQTT_TOPIC}")
    
    uvicorn.run(app, host=host, port=port, log_config=None)

