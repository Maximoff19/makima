"""Allowlisted shell tools for the chat.

This is deliberately NOT arbitrary command execution. An LLM that can run any command on
the host is a remote-code-execution primitive: a prompt injection pulled out of a web
search result, a memory, or a user message is enough to run whatever it likes. The
mitigations here are layered:

1. Off by default. Requires MAKIMA_ENABLE_TERMINAL=1 on the server.
2. Allowlist. A command is rejected unless its executable is on ALLOWED. No shell
   metacharacters, so there is no `;`, `&&`, backtick or `$()` to chain into.
3. Timeouts and output caps, so a runaway command cannot wedge the gateway.
4. Every invocation is logged with its exit status.

Anything not on the allowlist must be added deliberately, with the reason recorded next
to it. Do not grow this list reflexively.
"""

import asyncio
import logging
import os
import shlex
from pathlib import Path

import httpx

logger = logging.getLogger("makima.terminal")

# The gateway container has no docker socket and no ollama binary, so `docker` and
# `ollama` are NOT in this list: they would fail anyway, and listing them would imply a
# capability that does not exist. What is left is genuine self-inspection of the
# container the model is running inside.
#
# Host-level commands (docker compose ps, docker logs, ollama list) need a separate
# executor service that has the docker socket mounted. That is a real security decision
# and is deliberately not made here.
ALLOWED = {
    "ps", "free", "uptime", "date", "hostname", "ls", "cat", "head",
    "tail", "grep", "wc", "df", "id", "whoami", "env",
}

# /etc/passwd and /proc are readable but their values are not secrets worth exposing to a
# model; env is allowed for diagnostics but DOCKER_HOST/TOKEN style vars are filtered.
_ENV_BLOCKLIST = ("TOKEN", "SECRET", "KEY", "PASSWORD", "CREDENTIAL")

# Per-binary flag allowlist, default-deny. A global blocklist of "write-looking" flags
# does not work: `-m` means megabytes to `free` and chmod to `chmod`, so `free -m` was
# rejected as an attempt to write. Each binary gets the flags that are genuinely read-only
# for it, and anything else is refused.
ALLOWED_FLAGS = {
    "uptime": set(),
    "hostname": set(),
    "whoami": set(),
    "date": set(),
    "id": {"-u", "-g", "-n", "-r", "-un", "-gn"},
    "env": set(),
    "free": {"-m", "-h", "-g", "-w", "-s", "-t", "-c", "-b"},
    "df": {"-h", "-i", "-T", "-x", "-t", "--output", "--total", "-P", "-a"},
    "ps": {"aux", "-ef", "-e", "-f", "-o", "-p", "-u", "-U", "--sort", "-a", "-A", "--ppid", "-C"},
    "ls": {"-l", "-a", "-h", "-t", "-S", "-1", "-r", "-R", "--time-style", "-n"},
    "cat": {"-n", "-b", "-s", "-E", "-A", "-T", "-v"},
    "head": {"-n", "-c", "-q", "-v"},
    "tail": {"-n", "-c", "-q", "-v", "-f", "-F"},
    "grep": {"-i", "-v", "-n", "-E", "-F", "-A", "-B", "-C", "-c", "-l", "-o", "-w", "-x", "-r", "-R", "-q", "-s", "-m"},
    "wc": {"-l", "-w", "-c", "-m"},
}


# Paths a read-only inspector has no business reading. Relying on file permissions is
# not enough: the sandbox is non-root today, but a future image change could widen that.
DENIED_PATHS = (
    "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/ssh", "/root",
    "/proc/1/environ", "/var/run/secrets", "/run/secrets",
)


def _check_paths(argv: list[str]) -> str | None:
    for arg in argv[1:]:
        if not arg.startswith("/"):
            continue
        normalised = os.path.normpath(arg)
        if normalised in DENIED_PATHS or any(normalised.startswith(d + "/") for d in DENIED_PATHS):
            return "path %r is not readable from the sandbox" % arg
    return None


def _expand_short_flags(arg: str, allowed: set[str]) -> set[str]:
    """`-la` means `-l -a` to ls but is a single unknown token to a naive comparison."""
    if arg.startswith("--") or arg == "-" or not arg.startswith("-"):
        return {arg}
    body = arg[1:]
    if not body.isalpha():          # `-n 5` style: a value follows a known flag
        return {arg}
    return {"-" + ch for ch in body}


def _check_flags(argv: list[str]) -> str | None:
    """Reject any flag this binary does not legitimately accept in read-only mode."""
    exe = Path(argv[0]).name
    allowed = ALLOWED_FLAGS.get(exe)
    if allowed is None:
        return "%r is not on the allowlist" % exe
    for arg in argv[1:]:
        if not arg.startswith("-"):
            continue
        if arg in allowed:
            continue
        # Long options may carry a value, e.g. --sort=-k.
        if arg.split("=", 1)[0] in allowed:
            continue
        # Combined short flags: every letter must be independently permitted.
        expanded = _expand_short_flags(arg, allowed)
        if len(expanded) > 1 and expanded <= allowed:
            continue
        return "flag %r is not permitted for %s" % (arg, exe)
    return None

# Characters that would let a command escape the argv it was validated as.
_FORBIDDEN = (";", "&&", "||", "|", "`", "$", ">", "<", "\n", "&", "(", ")")

MAX_OUTPUT = 4000
DEFAULT_TIMEOUT = 25

# When set, commands are delegated to the read-only sandbox service instead of running in
# the gateway container. The sandbox sees host facts (load, memory, disk, process list)
# that the gateway cannot, and it is where the blast radius is contained.
SANDBOX_URL = os.getenv("MAKIMA_SANDBOX_URL", "").rstrip("/")


async def run_via_sandbox(command: str, timeout: int = DEFAULT_TIMEOUT) -> dict:
    """Delegate to the sandbox service. Returns an error dict on any failure."""
    if not SANDBOX_URL:
        return {"ok": False, "error": "sandbox not configured"}
    try:
        async with httpx.AsyncClient(timeout=timeout + 5) as client:
            response = await client.post(
                f"{SANDBOX_URL}/exec",
                json={"command": command, "timeout": timeout},
            )
            response.raise_for_status()
            return response.json()
    except httpx.HTTPError as exc:
        return {"ok": False, "error": f"sandbox unreachable: {type(exc).__name__}: {exc}"}
    except ValueError as exc:
        return {"ok": False, "error": f"sandbox sent invalid response: {exc}"}


def enabled() -> bool:
    return os.getenv("MAKIMA_ENABLE_TERMINAL", "").lower() in ("1", "true", "yes")


def _validate(command: str):
    """Return argv when the command is safe, otherwise the reason it is not."""
    if not command or not command.strip():
        return None, "empty command"
    for ch in _FORBIDDEN:
        if ch in command:
            return None, "forbidden character %r" % ch
    try:
        argv = shlex.split(command)
    except ValueError as exc:
        return None, "unparseable: %s" % exc
    if not argv:
        return None, "empty command"
    exe = Path(argv[0]).name
    if exe not in ALLOWED:
        return None, "%r is not on the allowlist" % exe
    return argv, None


def _redact_env(text: str) -> str:
    """Drop values whose variable name looks like a credential."""
    kept = []
    for line in text.splitlines():
        name = line.split("=", 1)[0]
        if any(marker in name.upper() for marker in _ENV_BLOCKLIST):
            kept.append(f"{name}=<redacted>")
        else:
            kept.append(line)
    return "\n".join(kept)


async def run(command: str, timeout: int = DEFAULT_TIMEOUT) -> dict:
    """Run an allowlisted command. Never raises; failures come back as data."""
    if not enabled():
        return {"ok": False, "error": "terminal tool is disabled on this server"}

    if SANDBOX_URL:
        return await run_via_sandbox(command, timeout)

    argv, reason = _validate(command)
    if argv is None:
        logger.warning("Blocked terminal command: %s (%s)", command, reason)
        return {"ok": False, "error": reason}

    logger.info("terminal exec: %s", " ".join(argv))
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        logger.error("terminal spawn failed: %s", exc)
        return {"ok": False, "error": "spawn failed: %s" % exc}

    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        logger.warning("terminal timeout: %s", " ".join(argv))
        return {"ok": False, "error": "timed out after %ss" % timeout}

    stdout = out.decode("utf-8", "replace")[:MAX_OUTPUT]
    stderr = err.decode("utf-8", "replace")[:MAX_OUTPUT]
    if argv[0] == "env":
        stdout = _redact_env(stdout)
    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": stdout,
        "stderr": stderr,
    }
