
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import logging
from logging.handlers import RotatingFileHandler
import os
import json
from typing import Dict, Any, Tuple, Optional
import requests
from requests.exceptions import RequestException
import uvicorn

# Configure logging
if not os.path.exists('logs'):
    os.makedirs('logs')

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

uvicorn_logger = logging.getLogger("uvicorn")
uvicorn_logger.setLevel(logging.INFO)

file_name = f'logs/{os.getenv("SERVICE_NAME", "legacy_proxy")}.log'
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
app = FastAPI(title="Legacy Proxy", description="HTTP to Legacy system service")

TARGET_URL = os.getenv('TARGET_URL', 'http://localhost:8080/ID_REQ_KC_STORE7D3BPACKET')

class Message(BaseModel):
    """Pydantic model for request validation"""
    id: str
    body: str

def on_message(message: str, request_id: Optional[str]) -> Tuple[bool, str]:
        try:
            headers = {"Request-Id": f"{request_id}"}
            response = requests.post(TARGET_URL, headers=headers, json=message)
            response.raise_for_status()
            return True, ""
        except RequestException as e:
            error_msg = f"[{request_id}] Failed to forward message to HTTP endpoint: {e}"
            logger.error(error_msg)
            return False, error_msg
        except Exception as e:
            error_msg = f"[{request_id}] Unexpected error while processing message: {e}"
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
       
        logger.info(f"[{request_id}] Forwarding message {message_str} to {TARGET_URL} ...")
        # Forward to Legacy System
        success, error = on_message(message_str, request_id)
        
        if not success:
            logger.error(f"[{request_id}] HTTP forward failed: {error}")
            raise HTTPException(
                status_code=500,
                detail=f"Failed to forward message: {error}"
            )

        logger.info(f"[{request_id}] Successfully forwarded message")
        return {
            "status": "success",
            "message": "Data published to Legacy System"
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
    logger.info(f"Forwarding to: {TARGET_URL}")
    
    uvicorn.run(app, host=host, port=port, log_config=None)

