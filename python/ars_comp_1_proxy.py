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
import socket
from urllib.parse import urlparse
import asyncio
from threading import Lock

# Configure logging
if not os.path.exists('logs'):
    os.makedirs('logs')

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

uvicorn_logger = logging.getLogger("uvicorn")
uvicorn_logger.setLevel(logging.DEBUG)

file_name = f'logs/{os.getenv("SERVICE_NAME", "ARS_Comp_1")}.log'
handler = RotatingFileHandler(
    file_name,
    maxBytes=100*1024*1024,  # 100MB
    backupCount=5
)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

logger.addHandler(handler)
uvicorn_logger.addHandler(handler)

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

# Initialize async HTTP client
httpclient:AsyncClient = None
resolved_target_url = ""

# Request rate tracking with sliding window
from collections import deque
request_timestamps = deque(maxlen=1000)  # Keep last 1000 request timestamps
request_lock = Lock()

@asynccontextmanager
async def lifespan(app: FastAPI):
    global httpclient, resolved_target_url
    # Startup: Resolve DNS and create a single persistent HTTP client
    resolved_target_url = resolve_hostname_to_ip(TARGET_URL)
    
    # Use resolved URL only when running with uvicorn (HTTP/1.1), original URL otherwise (HTTP/2 with granian)
    use_http2 = os.getenv('USE_HTTP_2', '').lower() in ('1', 'true', 'yes')
    
    httpclient = httpx.AsyncClient(
        http2=use_http2, # use http2 here because ARS_Comp_2 and LP1 use HTTP2.
        http1=not use_http2, # set to false to force http2 over plain text. Disabling http1 here, deactivates HTTP 1.1 Upgrade to HTTP 2.0
        timeout=httpx.Timeout(60.0),  # 60 second timeout
        limits=httpx.Limits(
            max_keepalive_connections=100,
            max_connections=None, # No limit
            keepalive_expiry=30.0
        )
    )
    logger.info(f"HTTP client initialized with resolved URL: {resolved_target_url}")
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


def get_connection_stats():
    """Get current connection pool statistics from httpx client"""
    if httpclient and hasattr(httpclient, '_transport'):
        try:
            # Try to get connection pool info from httpx transport
            transport = httpclient._transport
            if hasattr(transport, '_pool'):
                pool = transport._pool
                if hasattr(pool, '_connections'):
                    return len(pool._connections)
        except:
            pass
    return 0

def calculate_rps(window_seconds=5):
    """Calculate requests per second over the last window_seconds"""
    current_time = time.time()
    cutoff_time = current_time - window_seconds
    
    with request_lock:
        # Remove timestamps older than the window
        while request_timestamps and request_timestamps[0] < cutoff_time:
            request_timestamps.popleft()
        
        # Calculate RPS
        request_count = len(request_timestamps)
        return round(request_count / window_seconds, 1)


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

        response = await httpclient.post(resolved_target_url, headers=headers, json=json_object)
        logger.debug(f"[{request_id}] Response: %s", response.status_code)
        logger.debug(f"[{request_id}] HTTP version: %s", response.http_version)
        response.raise_for_status()
        return True, ""
    except HTTPStatusError as e:
        error_msg = f"[{request_id}] HTTP error {e.response.status_code}: {e.response.text}"
        return False, error_msg
    except RequestError as e:
        # Check if it's a timeout error specifically
        if 'timeout' in str(e).lower() or 'timed out' in str(e).lower():
            error_msg = f"[{request_id}] TIMEOUT sending to legacy proxy: {type(e).__name__}: {str(e) or repr(e)}"
        else:
            error_msg = f"[{request_id}] Failed to send message to legacy proxy: {type(e).__name__}: {str(e) or repr(e)}"
        return False, error_msg
        error_msg = f"[{request_id}] Unexpected error while processing message: {type(e).__name__}: {str(e) or repr(e)}"
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

@app.middleware("http")
async def track_request_rate(request: Request, call_next):
    start_time = time.time()
    request_id = request.headers.get('request-id', 'unknown')
    start_formatted = datetime.fromtimestamp(start_time).strftime('%H:%M:%S.%f')[:-3]
    logger.debug(f"[MIDDLEWARE_START][{request_id}] Request received at {start_formatted}")
    
    # Record request timestamp
    with request_lock:
        request_timestamps.append(start_time)
    
    response = await call_next(request)
    
    end_time = time.time()
    duration = end_time - start_time
    logger.debug(f"[MIDDLEWARE_END][{request_id}] Request completed in {duration:.3f}s")
    
    return response


@app.post("/api/v1/simple")
async def receive_simple_call(
    query_data: Optional[SimpleCall] = Depends(get_simple_call_from_query),
    body_data: Optional[SimpleCall] = Body(None),
    request_id: Annotated[str | None, Header()] = None
):
    endpoint_start = time.time()
    endpoint_formatted = datetime.fromtimestamp(endpoint_start).strftime('%H:%M:%S.%f')[:-3]
    logger.debug(f"[ENDPOINT_START][{request_id}] Handler started at {endpoint_formatted}")
    
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

        # Get current stats for enriched logging
        current_rps = calculate_rps()
        current_connections = get_connection_stats()
        
        logger.info(f"[rps:{current_rps}|conns:{current_connections}][{request_id}] Sending message {message_str} to {resolved_target_url} ...")

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
                timeout_keep_alive=60)

