from fastapi.encoders import jsonable_encoder
from fastapi import FastAPI, Body, Depends, Query, HTTPException, Header
from fastapi.responses import JSONResponse
from fastapi.requests import Request
from pydantic import BaseModel
from datetime import datetime
import time
from typing import Annotated, Optional, Tuple
from contextlib import asynccontextmanager
import os
import json
import logging
from logging.handlers import RotatingFileHandler
import httpx
from httpx import AsyncClient, HTTPStatusError, RequestError
import uvicorn
from uvicorn.protocols.http.h11_impl import H11Protocol

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

TARGET_URL = os.getenv('TARGET_URL', 'http://localhost:8080/ID_REQ_KC_STORE7D3BPACKET')

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
    title="ARS Comp 1 Proxy", 
    description="Proxy for ARS Comp 1",
    lifespan=lifespan
)


class LoggingH11Protocol(H11Protocol):
    def connection_made(self, transport):
        peername = transport.get_extra_info("peername")
        logger.debug(f"TCP connection from {peername}")
        super().connection_made(transport)

    def connection_lost(self, exc):
        if exc:
            logger.debug(f"TCP connection lost with error: {exc}")
        else:
            logger.debug("TCP connection closed gracefully")
        super().connection_lost(exc)


class SimpleCall(BaseModel):
    phone: str
    branch: str
    headnumber: str
    triggertime: datetime

    def __str__(self):
        return f"Phone: {self.phone}, Branch: {self.branch}, Headnumber: {self.headnumber}, TriggerTime: {self.triggertime}"


def get_simple_call_from_query(
    Phone: Optional[str] = Query(None),
    Branch: Optional[str] = Query(None),
    Headnumber: Optional[str] = Query(None),
    TriggerTime: Optional[datetime] = Query(None),
) -> Optional[SimpleCall]:
    if all([Phone, Branch, Headnumber, TriggerTime]):
        return SimpleCall(
            phone=Phone, branch=Branch, headnumber=Headnumber, triggertime=TriggerTime
        )
    return None


async def on_message(json_object, request_id) -> Tuple[bool, str]:
    try:
        headers = {"Request-Id": f"{request_id}"}

        response = await httpclient.post(TARGET_URL, headers=headers, json=json_object)
        logger.debug("[%i] Response: %s", request_id, response.status_code)
        logger.debug("[%i] HTTP version: %s", request_id, response.http_version)
        response.raise_for_status()
        return True, ""
    except HTTPStatusError as e:
        error_msg = f"[{request_id}] HTTP error {e.response.status_code}: {e.response.text}"
        return False, error_msg
    except RequestError as e:
        error_msg = f"[{request_id}] Failed to send message to legacy proxy: {e}"
        return False, error_msg
    except Exception as e:
        error_msg = f"[{request_id}] Unexpected error while processing message: {e}"
        return False, error_msg


# @app.exception_handler(Exception)
# async def global_exception_handler(request: Request, exc: Exception):
#     logger.error("Unhandled exception: %s", exc, exc_info=True)
#     return JSONResponse(status_code=500, content={"detail": "Internal Server Error"})
#
#
# @app.middleware("http")
# async def log_requests(request: Request, call_next):
#     start_time = time.time()
#     try:
#         response = await call_next(request)
#     except Exception as e:
#         logger.exception("Unhandled exception in request")
#         raise  # Let global exception handler handle it
#     duration = time.time() - start_time
#     logger.info(f"{request.method} {request.url.path} -> {response.status_code} in {duration:.3f}s")
#     return response


@app.post("/api/v1/simple")
async def receive_simple_call(
    query_data: Optional[SimpleCall] = Depends(get_simple_call_from_query),
    body_data: Optional[SimpleCall] = Body(None),
    request_id: Annotated[str | None, Header()] = None
):
    try:
        data = query_data or body_data
        if not data:
            return {"error": "Missing input: provide either query parameters or a JSON body."}

        # message_str = json.dumps(jsonable_encoder(data))
        message_str = str(data)
      
        json_msg = {
            'id': data.phone,
            'body': message_str
        }

        logger.info(f"[{request_id}] Sending message {message_str} to {TARGET_URL} ...")

        # Send to Legacy Proxy
        success, error = await on_message(json_msg, request_id)
        if not success:
            logger.error(f"[{request_id}] HTTP send failed: {error}")
            raise HTTPException(
                status_code=500,
                detail=f"Failed to send message: {error}"
            )

        logger.info(f"[{request_id}] Successfully send message")
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
    logger.info(f"Sending to: {TARGET_URL}")
    
    uvicorn.run(app, 
                host=host, 
                port=port, 
                log_config=None, 
                # http=LoggingH11Protocol, 
                timeout_keep_alive=60)

