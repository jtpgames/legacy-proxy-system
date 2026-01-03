# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## AI Assistant Preferences

### MCP Server Usage
When available, prefer using MCP (Model Context Protocol) servers for coding tasks:
- **Context7**: Use for gathering context-aware documentation and code examples
- **exa**: Use for searching technical documentation and research materials

MCP servers should be preferred over shell commands when they provide equivalent functionality.

## Development Commands

### Initial Setup
```bash
# Clone repository with submodules
git clone https://github.com/jtpgames/legacy-proxy-system.git && cd legacy-proxy-system && ./pull_all_submodules.sh

# Update submodules
./pull_all_submodules.sh

# Update all submodules to latest
./update_all_submodules.sh
```

### Docker-based Development
```bash
# Run legacy LPS experiment (direct HTTP forwarding)
cd python && docker-compose -f docker-compose-legacy.yml up --build

# Run new generation LPS experiment (MQTT-based messaging with Mosquitto)
cd python && docker-compose -f docker-compose-ng.yml up --build

# Run new generation LPS experiment (MQTT-based messaging with HiveMQ)
cd python && docker-compose -f docker-compose-ng-hivemq.yml up --build

# View logs from all services
cd python && docker-compose -f docker-compose-legacy.yml logs -f

# Clean up containers and volumes
cd python && docker-compose -f docker-compose-legacy.yml down -v
cd python && docker-compose -f docker-compose-ng.yml down -v
cd python && docker-compose -f docker-compose-ng-hivemq.yml down -v
```

### Running Individual Components
```bash
# Install Python dependencies (recommended: use virtual environment)
cd python && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt

# Run legacy proxy (direct HTTP forwarding)
cd python && python ars_comp_2_proxy.py

# Run ARS component proxy (client-facing proxy)
cd python && python ars_comp_1_proxy.py

# Run MQTT-based proxy 1 (HTTP to MQTT bridge)
cd python && python mqtt/legacy_proxy_1.py

# Run MQTT-based proxy 2 (MQTT to HTTP bridge)
cd python && python mqtt/legacy_proxy_2.py

# Run with traffic control simulation
cd python && ./start_python_app_with_tc.sh <script_name.py>
```

### Experiment Automation
```bash
# Run complete GS alarm system experiment
cd Automations && ./setup_and_run_gs_alarm_system_experiment.sh

# Run experiment with clean start (removes previous results)
cd Automations && ./setup_and_run_gs_alarm_system_experiment.sh --clean-start

# Manual experiment execution (examples)
cd Automations && ./start_experiment.sh -t legacy performance
cd Automations && ./start_experiment.sh -t ng failover 3
cd Automations && ./start_experiment.sh --with_fault_injector -t legacy failover 3
cd Automations && ./start_experiment.sh --without_timestamp -t ng failover 4

# Search for specific request IDs in logs
cd Automations && ./search_request_id.sh <request_id>
```

### Development Utilities
```bash
# Run fault injection (requires containers to be running)
cd python && python inject_fault.py

# Visualize Docker Compose system architecture
cd python && ./visualize-docker-compose-system.sh

# Start Python app with traffic control (network simulation)
cd python && ./start_python_app_with_tc.sh <python_script.py> [--use-granian]
```

## Code Architecture

### Legacy Proxy System (LPS) Overview
This repository implements and compares two LPS architectures for legacy system integration:

#### 1. Direct HTTP LPS (Legacy/Baseline)
- **Files**: `python/ars_comp_2_proxy.py`, `python/ars_comp_1_proxy.py`
- **Architecture**: Direct HTTP-to-HTTP forwarding
- **Flow**: `Client -> ARS Component Proxy -> Legacy Proxy -> Target Service`
- **Protocol**: Synchronous HTTP/2 requests throughout the chain
- **Configuration**: `docker-compose-legacy.yml`
- **Characteristics**: Low latency, tightly coupled, no persistence

#### 2. MQTT-based LPS (New Generation)
- **Files**: `python/mqtt/legacy_proxy_1.py`, `python/mqtt/legacy_proxy_2.py`
- **Architecture**: HTTP-to-MQTT-to-HTTP bridge pattern
- **Flow**: `Client -> ARS Component Proxy -> MQTT Bridge 1 -> MQTT Broker -> MQTT Bridge 2 -> Target Service`
- **Protocol**: HTTP to MQTT (asynchronous messaging) back to HTTP
- **Broker Options**: 
  - Mosquitto: `docker-compose-ng.yml`
  - HiveMQ: `docker-compose-ng-hivemq.yml` (default via symlink)
- **Characteristics**: Higher latency, decoupled, persistent messaging, better failover

### Key Components

#### ARS Component Proxy (`ars_comp_1_proxy.py`)
- **Framework**: FastAPI with Uvicorn/Granian ASGI server options
- **Role**: Client-facing proxy that accepts external requests
- **Features**:
  - Accepts REST API calls with query parameters or JSON body
  - Transforms calls to standardized message format
  - Propagates request IDs for distributed tracing
  - Supports HTTP/2 for high performance
- **Ports**: 7081-7083 (instances 1-3)
- **Environment Variables**: `HTTP_PORT`, `TARGET_URL`, `SERVICE_NAME`, `USE_HTTP_2`

#### ARS Component 2 Proxy (`ars_comp_2_proxy.py`)
- **Framework**: FastAPI with connection pooling
- **Role**: Direct HTTP forwarding proxy (legacy architecture only)
- **Features**:
  - HTTP/2 with persistent connections
  - Connection pooling with configurable limits
  - Request ID tracking and propagation
  - Targets Java-based RAST simulator
- **Ports**: 8081-8083 (legacy architecture)
- **Technology**: httpx with HTTP/2 support

#### MQTT Bridge 1 (`mqtt/legacy_proxy_1.py`)
- **Framework**: FastAPI + aiomqtt
- **Role**: HTTP-to-MQTT publisher bridge (new generation architecture)
- **Features**:
  - Receives HTTP requests via FastAPI endpoints
  - Publishes to MQTT broker using MQTTv5 protocol
  - QoS 2 (exactly-once delivery) for guaranteed message delivery
  - Persistent sessions with clean_start=False
  - Configurable broker connection and topic routing
  - Lifespan-managed MQTT client connection
- **Ports**: 8081-8083 (new generation architecture)
- **Environment Variables**: `MQTT_BROKER`, `MQTT_PORT`, `MQTT_TOPIC`, `HTTP_PORT`, `SERVICE_NAME`

#### MQTT Bridge 2 (`mqtt/legacy_proxy_2.py`)
- **Framework**: paho-mqtt + httpx
- **Role**: MQTT-to-HTTP subscriber bridge (new generation architecture)
- **Features**:
  - Subscribes to MQTT topics using shared subscriptions (`$share/legacy_proxy/+/message`)
  - Load balancing across multiple instances via shared subscriptions
  - MQTTv5 protocol with QoS 2
  - Manual acknowledgment for reliable message processing
  - Retry mechanism with separate retry topics
  - DNS caching for performance optimization
  - HTTP/2 support for downstream requests
  - Forwards messages to target HTTP services
  - Inflight window control (max_inflight_messages_set=1)
- **No External Ports**: Internal service only
- **Environment Variables**: `MQTT_HOST`, `MQTT_TOPIC`, `TARGET_URL`, `MQTT_QOS`, `SERVICE_NAME`, `USE_HTTP_2`, `SKIP_DNS_CACHE`

### Service Architecture

#### Legacy LPS Services (docker-compose-legacy.yml)
- **ars-comp-1-{1,2,3}**: Client-facing proxies (ports 7081-7083)
- **proxy-{1,2,3}**: Direct HTTP forwarding proxies (ports 8081-8083)
- **ars-comp-3**: Java-based RAST simulator service (port 8084)
- **Total Services**: 7 containers

#### New Generation LPS Services (docker-compose-ng.yml / docker-compose-ng-hivemq.yml)
- **ars-comp-1-{1,2,3}**: Client-facing proxies (ports 7081-7083)
- **proxy1-{1,2,3}**: HTTP-to-MQTT publisher bridges (ports 8081-8083)
- **proxy2-{1,2,3}**: MQTT-to-HTTP subscriber bridges (no external ports)
- **mosquitto** or **hivemq**: MQTT broker with persistence (port 1883)
  - Mosquitto: Lightweight, open-source broker
  - HiveMQ: Enterprise-grade broker (default configuration)
- **ars-comp-3**: Java-based RAST simulator service (port 8084)
- **Total Services**: 10 containers

### Network Simulation
All proxy containers use traffic control (`tc`) via `start_python_app_with_tc.sh` to simulate realistic network conditions:
- **Download**: 2 Mbit/s with 100ms latency (egress)
- **Upload**: 1 Mbit/s with 40ms±10ms jitter (ingress)
- **Purpose**: Simulate VDSL/ADSL connections for realistic edge deployment scenarios
- **Implementation**: Applied via `cap_add: NET_ADMIN` capability and shell script wrapper
- **Note**: Controlled by `HOST_OS` environment variable to enable/disable on different platforms

### Experiment Framework
- **Automation**: Shell scripts in `Automations/` directory
  - `setup_and_run_gs_alarm_system_experiment.sh`: Main orchestration script
  - `start_experiment.sh`: Configurable experiment runner (42KB, extensive)
  - `run_experiment.sh`: Experiment execution helper
  - `search_request_id.sh`: Log analysis tool for request tracing
- **Experiment Types**: 
  - Performance testing (throughput, latency measurements)
  - Failover testing (resilience with 3-4 minute durations)
  - Fault injection experiments (using `inject_fault.py`)
- **Test Scenarios**: Uses Locust load testing framework with GS Alarm System production logs
- **Measurement**: Execution time tracking, detailed logging, request ID correlation
- **Results Storage**: 
  - `Baseline_Experiment/`: Legacy LPS experiment results
  - `NG_Experiment/`: New generation LPS experiment results
- **Flags**: 
  - `--clean-start`: Remove previous results
  - `--with_fault_injector`: Enable fault injection
  - `--without_timestamp`: Consistent naming for comparison
  - `-t legacy|ng`: Select architecture type

### Dependencies and Submodules

#### Git Submodules
- **Simulators/**: Java-based RAST simulator (target service implementation)
- **locust_scripts/**: Load testing scenarios based on production logs
- **RAST-Common-Python/**: Shared Python utilities and common modules
- **hivemq/**: HiveMQ broker configuration and setup

#### Python Dependencies (requirements.txt)
- **FastAPI 0.115.8**: Modern async web framework for HTTP endpoints
- **aiomqtt 2.4.0**: Async MQTT client library (MQTTv5)
- **pydantic 2.10.6**: Data validation using Python type annotations
- **httpx[http2] 0.28.1**: HTTP client with HTTP/2 support
- **uvicorn[standard] 0.34.0**: ASGI server (alternative: Granian)
- **requests 2.32.3**: HTTP library for simple requests
- **docker 7.1.0**: Docker SDK for Python
- **typer 0.16.0**: CLI application framework
- **APScheduler 3.11.0**: Advanced Python scheduler for fault injection
- **paho-mqtt**: MQTT client library (used in legacy_proxy_2.py)

#### MQTT Broker Options
- **Mosquitto**: Lightweight open-source MQTT broker
- **HiveMQ**: Enterprise-grade MQTT broker (default configuration)

### Logging and Observability
- **Log Rotation**: RotatingFileHandler (100MB max per file, 5 backups)
- **Request Tracing**: Request ID propagation throughout entire proxy chain
- **Storage**: Container-level logging with bind mounts to `./logs/` directory
- **Naming Convention**: Service-specific log files based on `SERVICE_NAME` environment variable
  - Format: `logs/<SERVICE_NAME>.log`
  - Examples: `ars-comp-1-1.log`, `proxy1-2.log`, `proxy2-3.log`
- **Log Levels**: DEBUG level for detailed troubleshooting, INFO for operational visibility
- **Request Correlation**: Request ID in format `[<request_id>]` throughout log messages
- **Analysis Tools**: `search_request_id.sh` for cross-service request tracing
- **MQTT Logging**: Both aiomqtt and paho-mqtt provide detailed protocol-level logs

## Performance Optimizations

### TCP Tuning
All containers include sysctl configurations for high-throughput scenarios:
- `net.ipv4.tcp_max_syn_backlog=2048`: Expanded SYN packet backlog
- `net.ipv4.tcp_fin_timeout=30`: Reduced connection cleanup time
- `net.ipv4.ip_local_port_range=1024 61000`: Expanded ephemeral port range
- `net.ipv4.tcp_abort_on_overflow=1`: Immediate rejection instead of silent drops

### HTTP/2 Configuration
- Connection pooling with configurable limits (max_keepalive_connections=100)
- Persistent connections with 30-second keepalive expiry
- HTTP/2 over cleartext (h2c) for internal service communication
- Controlled via `USE_HTTP_2` environment variable

### MQTT Optimizations
- QoS 2 for exactly-once delivery guarantees
- Shared subscriptions for load balancing (`$share/legacy_proxy/...`)
- Clean start disabled (clean_start=False) for persistent sessions
- Inflight window limiting (max_inflight_messages_set=1) for backpressure
- DNS caching in legacy_proxy_2 for reduced resolution overhead

### ASGI Server Options
- **Uvicorn**: Default ASGI server with good performance
- **Granian**: High-performance Rust-based ASGI server (via `--use-granian` flag)
- Configured in `start_python_app_with_tc.sh` script
