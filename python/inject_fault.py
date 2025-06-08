import time
import docker
import typer
import signal
import sys
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

def handle_sigterm(signum, frame):
    logger.info("Received SIGTERM, exiting...")
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_sigterm)
signal.signal(signal.SIGINT, handle_sigterm)

app = typer.Typer()
client = docker.from_env()

def get_container(target_service: str):
    containers = client.containers.list(all=True, filters={"name": target_service})
    return containers[0] if containers else None

def stop_start(container, target_service: str, duration_down: int):
    logger.info("[STOP] Stopping service '%s'", target_service)
    container.stop()
    time.sleep(duration_down)
    logger.info("[STOP] Starting service '%s'", target_service)
    container.start()

def add_netem(container, target_service: str, duration_down: int):
    logger.info("[NET] Adding latency to service '%s'", target_service)
    try:
        container.exec_run("tc qdisc add dev eth0 root netem delay 1000ms")
        time.sleep(duration_down)
        logger.info("[NET] Removing latency from service '%s'", target_service)
        container.exec_run("tc qdisc del dev eth0 root netem")
    except Exception as e:
        logger.error("[NET] Network emulation failed for service '%s': %s", target_service, e)

def stress_cpu(container, target_service: str, duration_down: int):
    logger.info("[CPU] Stressing CPU on service '%s'", target_service)
    try:
        container.exec_run(
            "sh -c 'which stress || apk add --no-cache stress || apt-get update && apt-get install -y stress'",
            tty=True,
        )
        container.exec_run(f"stress --cpu 1 --timeout {duration_down}", tty=True)
    except Exception as e:
        logger.error("[CPU] CPU stress failed for service '%s': %s", target_service, e)

@app.command()
def main(
    target_service: str = typer.Option("target-service", help="Target container name"),
    fault_mode: str = typer.Option("stop", help="Fault mode: stop, net, cpu"),
    duration_down: int = typer.Option(10, help="Seconds the fault is applied"),
    duration_up: int = typer.Option(30, help="Seconds between faults"),
):
    logger.info("Starting fault injection - target_service: '%s', fault_mode: '%s', duration_down: %d, duration_up: %d", 
                target_service, fault_mode, duration_down, duration_up)
    
    while True:
        container = get_container(target_service)
        if not container:
            logger.warning("[WARN] Target container '%s' not found. Retrying in 5 seconds...", target_service)
            time.sleep(5)
            continue

        try:
            if fault_mode == "stop":
                stop_start(container, target_service, duration_down)
            elif fault_mode == "net":
                add_netem(container, target_service, duration_down)
            elif fault_mode == "cpu":
                stress_cpu(container, target_service, duration_down)
            else:
                logger.error("[ERROR] Unknown fault mode: '%s'", fault_mode)
                continue
        except Exception as e:
            logger.error("[ERROR] Exception occurred during fault injection: %s", e)

        logger.info("[WAIT] Sleeping for %d seconds before next fault injection cycle", duration_up)
        time.sleep(duration_up)

if __name__ == "__main__":
    app()
