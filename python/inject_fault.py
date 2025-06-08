import time
import docker
import typer
import signal
import sys

def handle_sigterm(signum, frame):
    print("Received SIGTERM, exiting...")
    sys.exit(0)

signal.signal(signal.SIGTERM, handle_sigterm)
signal.signal(signal.SIGINT, handle_sigterm)

app = typer.Typer()
client = docker.from_env()

def get_container(target_service: str):
    containers = client.containers.list(all=True, filters={"name": target_service})
    return containers[0] if containers else None

def stop_start(container, target_service: str, duration_down: int):
    print(f"[STOP] Stopping {target_service}...")
    container.stop()
    time.sleep(duration_down)
    print(f"[START] Starting {target_service}...")
    container.start()

def add_netem(container, target_service: str, duration_down: int):
    print(f"[NET] Adding latency to {target_service}...")
    try:
        container.exec_run("tc qdisc add dev eth0 root netem delay 1000ms")
        time.sleep(duration_down)
        print(f"[NET] Removing latency from {target_service}...")
        container.exec_run("tc qdisc del dev eth0 root netem")
    except Exception as e:
        print(f"[ERROR] Network emulation failed: {e}")

def stress_cpu(container, target_service: str, duration_down: int):
    print(f"[CPU] Stressing CPU on {target_service}...")
    try:
        container.exec_run(
            "sh -c 'which stress || apk add --no-cache stress || apt-get update && apt-get install -y stress'",
            tty=True,
        )
        container.exec_run(f"stress --cpu 1 --timeout {duration_down}", tty=True)
    except Exception as e:
        print(f"[ERROR] CPU stress failed: {e}")

@app.command()
def main(
    target_service: str = typer.Option("target-service", help="Target container name"),
    fault_mode: str = typer.Option("stop", help="Fault mode: stop, net, cpu"),
    duration_down: int = typer.Option(10, help="Seconds the fault is applied"),
    duration_up: int = typer.Option(30, help="Seconds between faults"),
):
    while True:
        container = get_container(target_service)
        if not container:
            print("[WARN] Target container not found. Retrying...")
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
                print(f"[ERROR] Unknown fault mode: {fault_mode}")
        except Exception as e:
            print(f"[ERROR] Exception occurred: {e}")

        print(f"[WAIT] Sleeping for {duration_up} seconds...")
        time.sleep(duration_up)

if __name__ == "__main__":
    app()
