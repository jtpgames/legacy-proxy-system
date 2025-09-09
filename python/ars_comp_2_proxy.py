
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import logging
from logging.handlers import RotatingFileHandler
import os
import json
from typing import Dict, Any, Tuple, Optional
import httpx
from httpx import AsyncClient, HTTPStatusError, RequestError
from contextlib import asynccontextmanager
import uvicorn

# Configure logging
if not os.path.exists('logs'):
    os.makedirs('logs')

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

uvicorn_logger = logging.getLogger("uvicorn")
uvicorn_logger.setLevel(logging.INFO)

file_name = f'logs/{os.getenv("SERVICE_NAME", "ARS_Comp_2")}.log'
handler = RotatingFileHandler(
    file_name,
    maxBytes=10*1024*1024,  # 10MB
    backupCount=5
)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

logger.addHandler(handler)
uvicorn_logger.addHandler(handler)

# Initialize async HTTP client
httpclient:AsyncClient = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global httpclient
    # Startup: Create a single persistent HTTP client for better performance
    httpclient = httpx.AsyncClient(
        http2=True,
        timeout=httpx.Timeout(60.0),  # 60 second timeout
        limits=httpx.Limits(
            max_keepalive_connections=100,
            max_connections=None, # No limit
            keepalive_expiry=30.0
        )
    )
    logger.info("HTTP client initialized")
    yield
    # Shutdown: Close the HTTP client
    if httpclient:
        await httpclient.aclose()
        logger.info("HTTP client closed")

# Initialize FastAPI app with lifespan
app = FastAPI(
    title="ARS Component 2 Proxy", 
    description="HTTP to target system service",
    lifespan=lifespan
)

TARGET_URL = os.getenv('TARGET_URL', 'http://localhost:8080/ID_REQ_KC_STORE7D3BPACKET')

class Message(BaseModel):
    """Pydantic model for request validation"""
    id: str
    body: str

async def on_message(json_object, request_id) -> Tuple[bool, str]:
    try:
        headers = {"Request-Id": f"{request_id}"}
        response = await httpclient.post(TARGET_URL, headers=headers, json=json_object)
        logger.debug(f"[{request_id}] Response: %s", response.status_code)
        logger.debug(f"[{request_id}] HTTP version: %s", response.http_version)
        response.raise_for_status()
        return True, ""
    except HTTPStatusError as e:
        error_msg = f"[{request_id}] HTTP error {e.response.status_code}: {e.response.text}"
        logger.error(error_msg)
        return False, error_msg
    except RequestError as e:
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
        success, error = await on_message(message_str, request_id)
        
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
    
    uvicorn.run(app, host=host, port=port, log_config=None, timeout_keep_alive=60)

