from typing import List, Optional
import docker
import typer
import signal
import sys
import logging

from random import random, seed
from time import sleep
from apscheduler.schedulers.background import BackgroundScheduler
from dataclasses import dataclass
from datetime import datetime, timedelta


@dataclass
class FaultAndRecoveryModel:
    operator_reaction_time_s: float
    ars_recovery_time_s: float
    fault_detection_time_range_s: tuple
    this_ARS_number_in_the_server_list: int


@dataclass()
class StopOnceState:
    containers_to_stop: List
    services_to_stop: List[str]
    currentServiceIndex: int
    stop_service_after_sec: int


def get_next_service_to_stop_once(stop_once_state: StopOnceState) -> int:
    if stop_once_state.currentServiceIndex + 1 < len(stop_once_state.services_to_stop):
        return stop_once_state.currentServiceIndex + 1
    return -1


def between(min, max):
    return min + random() * (max - min)


def notify_operator(container, target_service: str):
    logger.debug("operator reaction time: %f", current_model.operator_reaction_time_s)

    # Simulate the time it takes until an operator reacts to the notification
    # we call this operator reaction time
    due_date = datetime.now() + timedelta(0, current_model.operator_reaction_time_s)
    scheduler.add_job(recover, 'date', run_date=due_date, args=[container, target_service])


def recover(container, target_service: str):
    # Simulate the time an operator needs to perform a recovery action
    # we call this recovery action time
    sleep(current_model.ars_recovery_time_s)

    global _is_faulted
    _is_faulted = False

    start_container(container, target_service)

    global time_of_recovery
    time_of_recovery = datetime.now()

    logger.info("*%s* recovered @%s", target_service, time_of_recovery)
    global stop_once_state
    if stop_once_state is not None:
        next_service_index_to_stop = get_next_service_to_stop_once(stop_once_state)
        if next_service_index_to_stop != -1:
            stop_once_state.currentServiceIndex = next_service_index_to_stop
            inject_a_fault_once_after_s_seconds(stop_once_state)


def is_faulted():
    return _is_faulted


def inject_a_fault_every_s_seconds(container, target_service: str, s):
    scheduler.add_job(simulate_fault, 'interval', seconds=s, args=[container, target_service])


def inject_a_fault_once_after_s_seconds(stop_once_state: StopOnceState):
    container = stop_once_state.containers_to_stop[stop_once_state.currentServiceIndex]
    target_service = stop_once_state.services_to_stop[stop_once_state.currentServiceIndex]

    run_date_for_next_job = datetime.now() + timedelta(seconds=stop_once_state.stop_service_after_sec)
    scheduler.add_job(
            simulate_fault, 
            'date',
            run_date=run_date_for_next_job,
            args=[container, target_service]
    )


def inject_three_faults_in_a_row(container, target_service):
    due_date1 = datetime.now() + timedelta(0, minutes=5)
    due_date2 = due_date1 + timedelta(0, 60)
    due_date3 = due_date2 + timedelta(0, 60)

    scheduler.add_job(simulate_fault, 'date', run_date=due_date1, args=[container, target_service])
    scheduler.add_job(simulate_fault, 'date', run_date=due_date2, args=[container, target_service])
    scheduler.add_job(simulate_fault, 'date', run_date=due_date3, args=[container, target_service])
    scheduler.add_job(inject_three_faults_in_a_row, 'date', run_date=due_date3, args=[container, target_service])


def simulate_fault(container, target_service):
    """
    simulate a fault:
    *
    * this method causes the function `is_faulted` to return true for `chosen_fault_time` seconds.
    * `chosen_fault_time` is set using the fault_detection_time_range_s of the current_model.
    """

    if is_faulted():
        logger.debug("Still faulty")
        return

    global chosen_fault_time

    # fault detection time:
    # indicates how long the fault detection mechanism requires to detect a fault
    chosen_fault_time = between(current_model.fault_detection_time_range_s[0],
                                current_model.fault_detection_time_range_s[1])

    logger.debug("chosen_fault_time: %f", chosen_fault_time)

    # + delay until check
    # the fault detection mechanism needs more time depending on the
    # position of the ARS in the "checklist".
    chosen_fault_time += 2 * (current_model.this_ARS_number_in_the_server_list - 1)

    logger.debug("# + delay until check: %f", chosen_fault_time)

    stop_container(container, target_service)

    global time_of_last_fault
    time_of_last_fault = datetime.now()

    logger.info("*%s* faulted @%s; operator will be notified in %ss",
                target_service,
                time_of_last_fault,
                chosen_fault_time)

    global _is_faulted
    _is_faulted = True

    due_date = datetime.now() + timedelta(0, chosen_fault_time)
    scheduler.add_job(notify_operator, 'date', run_date=due_date, args=[container, target_service])

# -- Fault Management Model --
# (26, 34) are the minimum and maximum times,
# the fault detection mechanism needs to detect a fault,
# based on the real-world fault detection mechanism.
# For every ARS running in the system, we have additional 2 seconds,
# so we include the position of the ARS in the "check list", to account for that.
#
# In addition to that, we have operator time---the time an operator needs to begin his work---
# and recovery time---the time the recovery action requires, e.g., how much time it takes to restart the ARS.
# --
model_production_ideal = FaultAndRecoveryModel(1, 0.5, (26, 34), 2)

current_model = model_production_ideal

scheduler = BackgroundScheduler(misfire_grace_time=None)
time_of_last_fault = datetime.now()
time_of_recovery = datetime.now()
chosen_fault_time: float = 0
_is_faulted = False

stop_once_state: Optional[StopOnceState] = None

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,
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

def stop_container(container, target_service: str):
    logger.info("[STOP] Stopping service '%s'", target_service)
    container.stop()

def start_container(container, target_service: str):
    logger.info("[STOP] Starting service '%s'", target_service)
    container.start()

def add_netem(container, target_service: str, duration_down: int):
    logger.info("[NET] Adding latency to service '%s'", target_service)
    try:
        container.exec_run("tc qdisc add dev eth0 root netem delay 1000ms")
        sleep(duration_down)
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
    target_service: List[str] = typer.Option(..., "--target-service", help="Target container name. For stop_once fault mode, multiple services can be specified that are used in sequence."),
    fault_mode: str = typer.Option("stop", help="Fault mode: stop, stop_once, net, cpu"),
    duration_down: int = typer.Option(10, help="Seconds the fault is applied. Does not apply for stop mode."),
    duration_up: int = typer.Option(30, help="Seconds between faults"),
    initial_wait: float = typer.Option(0, help="Seconds before injecting faults"),
):
    logger.info("Starting fault injection - target_service: '%s', fault_mode: '%s', duration_down: %d, duration_up: %d", 
                target_service, fault_mode, duration_down, duration_up)
 
    sleep(initial_wait)

    # initialize the random seed value to get reproducible random sequences
    seed(42)

    while True:
        containers = []
        for t in target_service:
            container = get_container(t)
            if not container:
                logger.warning("[WARN] Target container '%s' not found. Retrying in 5 seconds...", target_service)
                sleep(5)
                continue
            containers.append(container)

        try:
            if fault_mode == "stop" or fault_mode == "stop_once":
                scheduler.start()
                if fault_mode == "stop_once":
                    global stop_once_state
                    stop_once_state = StopOnceState(containers_to_stop=containers, services_to_stop=target_service, currentServiceIndex=0, stop_service_after_sec=duration_up)
                    inject_a_fault_once_after_s_seconds(stop_once_state)
                else:
                    inject_a_fault_every_s_seconds(containers[0], target_service[0], duration_up)
                # Block main thread indefinitely
                try:
                    while True:
                        sleep(1)
                except (KeyboardInterrupt, SystemExit):
                    logger.info("Shutting down scheduler")
                    scheduler.shutdown()
                    sys.exit(0)
            elif fault_mode == "net":
                add_netem(containers[0], target_service[0], duration_down)
            elif fault_mode == "cpu":
                stress_cpu(containers[0], target_service[0], duration_down)
            else:
                logger.error("[ERROR] Unknown fault mode: '%s'", fault_mode)
                continue
        except Exception as e:
            logger.error("[ERROR] Exception occurred during fault injection: %s", e)

        logger.info("[WAIT] Sleeping for %d seconds before next fault injection cycle", duration_up)
        sleep(duration_up)


if __name__ == "__main__":
    app()
