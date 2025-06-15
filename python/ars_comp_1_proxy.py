from fastapi import FastAPI, Body, Depends, Query, HTTPException
from pydantic import BaseModel
from datetime import datetime
from typing import Optional, Tuple
import os
import json
import logging
from logging.handlers import RotatingFileHandler
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

file_name = f'logs/{os.getenv("SERVICE_NAME", "ARS_Comp_1")}.log'
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
app = FastAPI(title="ARS Comp 1 Proxy", description="Proxy for ARS Comp 1")

TARGET_URL = os.getenv('TARGET_URL', 'http://localhost:8080/ID_REQ_KC_STORE7D3BPACKET')


class SimpleCall(BaseModel):
    Phone: str
    Branch: str
    Headnumber: str
    TriggerTime: datetime

    def __str__(self):
        return f"Phone: {self.Phone}, Branch: {self.Branch}, Headnumber: {self.Headnumber}"


def get_simple_call_from_query(
    Phone: Optional[str] = Query(None),
    Branch: Optional[str] = Query(None),
    Headnumber: Optional[str] = Query(None),
    TriggerTime: Optional[datetime] = Query(None),
) -> Optional[SimpleCall]:
    if all([Phone, Branch, Headnumber, TriggerTime]):
        return SimpleCall(
            Phone=Phone, Branch=Branch, Headnumber=Headnumber, TriggerTime=TriggerTime
        )
    return None


def on_message(message: str) -> Tuple[bool, str]:
        try:
            response = requests.post(TARGET_URL, json=message)
            response.raise_for_status()
            return True, ""
        except RequestException as e:
            error_msg = f"Failed to send message to legacy proxy: {e}"
            return False, error_msg
        except Exception as e:
            error_msg = f"Unexpected error while processing message: {e}"
            return False, error_msg


@app.post("/api/v1/simple")
async def receive_simple_call(
    query_data: Optional[SimpleCall] = Depends(get_simple_call_from_query),
    body_data: Optional[SimpleCall] = Body(None),
):
    try:
        data = query_data or body_data
        if not data:
            return {"error": "Missing input: provide either query parameters or a JSON body."}

        message_str = json.dumps(data)
        
        # Publish to Legacy System
        success, error = on_message(message_str)
        if not success:
            logger.error(f"HTTP forward failed: {error}")
            raise HTTPException(
                status_code=500,
                detail=f"Failed to send message: {error}"
            )

        logger.info(f"Successfully send message: {message_str} to {TARGET_URL}")
        return {
            "status": "success",
            "message": "Data published to Legacy System"
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
    logger.info(f"Sending to: {TARGET_URL}")
    
    uvicorn.run(app, host=host, port=port, log_config=None)

