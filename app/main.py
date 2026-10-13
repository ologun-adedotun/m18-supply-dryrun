import json
import logging
import os
import random
import sys
import time

from fastapi import FastAPI, Query, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# Settings come from environment variables, with a safe default for each.
APP_NAME = os.environ.get("APP_NAME", "maright-app")
GREETING = os.environ.get("GREETING", "Hello from Mission Control")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
READY_AFTER_SECONDS = float(os.environ.get("READY_AFTER_SECONDS", "5"))
APP_VERSION = os.environ.get("APP_VERSION", "dev")
# Fault settings for progressive delivery labs. Both default to "no fault".
ERROR_RATE = float(os.environ.get("ERROR_RATE", "0"))
DELAY_MS = int(os.environ.get("DELAY_MS", "0"))
if not 0.0 <= ERROR_RATE <= 1.0 or not 0 <= DELAY_MS <= 5000:
    raise SystemExit("ERROR_RATE must be 0 to 1 and DELAY_MS 0 to 5000")


class JsonFormatter(logging.Formatter):
    """Write every log line as one line of JSON, so a computer can read it."""

    def format(self, record):
        return json.dumps({
            "time": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "app": APP_NAME,
            "message": record.getMessage(),
        })


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger(APP_NAME)
log.addHandler(handler)
log.setLevel(LOG_LEVEL)
log.propagate = False

REQUESTS = Counter("app_requests_total", "Requests answered, by path", ["path"])
RESPONSES = Counter("app_responses_total", "Responses sent, by path and status code", ["path", "code"])
LATENCY = Histogram(
    "app_request_duration_seconds", "Time taken to answer, by path", ["path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
KNOWN_PATHS = {"/", "/health", "/ready", "/metrics", "/work"}
STARTED = time.time()

app = FastAPI(title=APP_NAME)
log.info("starting up")


@app.middleware("http")
async def measure(request, call_next):
    """Count every response by status code, and time it."""
    start = time.perf_counter()
    response = await call_next(request)
    path = request.url.path if request.url.path in KNOWN_PATHS else "other"
    RESPONSES.labels(path=path, code=str(response.status_code)).inc()
    LATENCY.labels(path=path).observe(time.perf_counter() - start)
    return response


@app.get("/")
def home(response: Response):
    REQUESTS.labels(path="/").inc()
    if DELAY_MS:
        time.sleep(DELAY_MS / 1000)
    if ERROR_RATE and random.random() < ERROR_RATE:
        response.status_code = 500
        return {"app": APP_NAME, "version": APP_VERSION, "status": "failed"}
    log.info("home page served")
    return {"app": APP_NAME, "version": APP_VERSION, "message": GREETING}


@app.get("/health")
def health():
    REQUESTS.labels(path="/health").inc()
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    REQUESTS.labels(path="/ready").inc()
    if time.time() - STARTED < READY_AFTER_SECONDS:
        response.status_code = 503
        return {"status": "starting"}
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/work")
def work(
    response: Response,
    ms: int = Query(0, ge=0, le=30000),
    cpu_ms: int = Query(0, ge=0, le=2000),
    fail: float = Query(0.0, ge=0.0, le=1.0),
):
    """Simulated work: wait ms, burn cpu_ms of CPU, then fail a share of requests."""
    REQUESTS.labels(path="/work").inc()
    if cpu_ms:
        end = time.perf_counter() + cpu_ms / 1000
        while time.perf_counter() < end:
            pass
    if ms:
        time.sleep(ms / 1000)
    if fail and random.random() < fail:
        response.status_code = 503
        return {"status": "failed"}
    return {"status": "done"}
