"""Read-only sandbox for the terminal tool.

The gateway container cannot inspect the host: no docker socket, no ollama binary, and
`read_only: true` as UID 10001. So the terminal tool could only ever report on the gateway
process itself, which is not what someone asking "how is the VPS doing" wants.

This service exists to give the model a real, if narrow, view of the box. The design
constraint is that it must never be a path back into the host, so:

* it is a separate container on the private network only, with no published ports
* it does NOT mount the docker socket - the single most dangerous mount on a Linux host
* the filesystem is read-only, plus one tmpfs for scratch
* it runs unprivileged with a CPU, memory and PID cap, and every command has a timeout
* the command allowlist is shared with the gateway so both sides agree on what is allowed
* writes are refused: this is an inspection tool, not a shell

What it can genuinely do is read host facts: load, memory, disk, process list, and the
tail of the compose and log files that are bind-mounted read-only.
"""

import logging
import os
import shlex
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

import os

import terminal

# The gateway already checked MAKIMA_ENABLE_TERMINAL before calling. The sandbox is the
# executor, so it must not gate on it again or it refuses its own requests.
os.environ.setdefault("MAKIMA_ENABLE_TERMINAL", "1")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("makima.sandbox")

app = FastAPI(title="makima sandbox", docs_url=None, redoc_url=None)

# Only these paths are bind-mounted in, read-only.
READABLE_ROOTS = ("/host",)


class Command(BaseModel):
    command: str = Field(min_length=1, max_length=400)
    timeout: int = Field(default=terminal.DEFAULT_TIMEOUT, ge=1, le=60)


@app.get("/health")
async def health() -> dict:
    return {"ok": True}


@app.post("/exec")
async def exec_command(req: Command) -> dict:
    """Run one allowlisted read-only command. Shares the gateway's validation."""
    argv, reason = terminal._validate(req.command)
    if argv is None:
        logger.warning("sandbox blocked: %s (%s)", req.command, reason)
        raise HTTPException(400, reason)

    # Per-binary flag allowlist, default-deny. See terminal.ALLOWED_FLAGS: a global
    # blocklist misreads `-m` and rejects `free -m`.
    bad_flag = terminal._check_flags(argv)
    if bad_flag:
        raise HTTPException(400, bad_flag)
    bad_path = terminal._check_paths(argv)
    if bad_path:
        raise HTTPException(400, bad_path)

    logger.info("sandbox exec: %s", " ".join(argv))
    result = await terminal.run(req.command, timeout=req.timeout)
    if not result.get("ok") and "spawn failed" in str(result.get("error", "")):
        raise HTTPException(500, result["error"])
    return result
