from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import paho.mqtt.publish as mqtt
import logging
from logging.handlers import RotatingFileHandler
import os
import json
from typing import Dict, Any, Tuple, Optional
import uvicorn

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
    maxBytes=10*1024*1024,  # 10MB
    backupCount=5
)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

logger.addHandler(handler)
uvicorn_logger.addHandler(handler)

# Initialize FastAPI app
app = FastAPI(title="Legacy Proxy I", description="HTTP to MQTT bridge service")

# Get configuration from environment variables with defaults
MQTT_BROKER = os.getenv('MQTT_BROKER', 'localhost')
MQTT_PORT = os.getenv('MQTT_PORT', '1883')
MQTT_TOPIC = os.getenv('MQTT_TOPIC', 'default/topic')

class Message(BaseModel):
    """Pydantic model for request validation"""
    id: str
    body: str

def publish_to_mqtt(message: str) -> Tuple[bool, str]:
    """
    Publish a message to MQTT broker using paho-mqtt with QoS 2.
    
    Returns:
        Tuple[bool, str]: Success status and error message if any
    """
    try:
        mqtt.single(
            topic=MQTT_TOPIC,
            payload=message,
            qos=2,
            hostname=MQTT_BROKER,
            port=int(MQTT_PORT)
        )
        return True, ""
    except mqtt.MQTTException as e:
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
        
        # Publish to MQTT
        success, error = publish_to_mqtt(message_str)
        
        if not success:
            logger.error(f"MQTT publish failed: {error}")
            raise HTTPException(
                status_code=500,
                detail=f"Failed to publish message: {error}"
            )

        logger.info(f"Successfully published message: {message_str}")
        return {
            "status": "success",
            "message": "Data published to MQTT"
        }

    except Exception as e:
        logger.error(f"Error processing request: {str(e)}")
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

