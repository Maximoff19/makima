"""Translate Makima Responses requests to a private, isolated OpenCode session."""

import asyncio
import json
import logging
import os
import re
import shlex
import time
from pathlib import Path
from uuid import uuid4
from urllib.parse import urlsplit

import httpx
import agenda
from anyio import CancelScope
from fastapi import HTTPException
from fastapi.responses import StreamingResponse

logger = logging.getLogger("makima")
OPENCODE_URL = os.getenv("MAKIMA_OPENCODE_URL", "http://opencode:4096")
PASSWORD_FILE = Path(os.getenv("MAKIMA_OPENCODE_PASSWORD_FILE", "/run/secrets/opencode_password"))
SESSION_DIR = Path(os.getenv("MAKIMA_OPENCODE_SESSION_DIR", "/data/opencode-sessions"))
SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,100}$")

# A turn the gateway could not answer (tool timeout, upstream 5xx, empty completion) stays in
# the client's transcript as a bare USER message: the phone keeps the user's text and only
# attaches an error flag it never puts on the wire. Two adjacent USER turns therefore read as
# "carry on", and the model answers the abandoned task instead of the newest message — which is
# exactly the reported symptom: after a failed task, "hola" came back with a recap of what the
# agent had done and no reply to the new request. Closing each unanswered turn explicitly makes
# the last message the only open request.
FAILED_TURN = "ASSISTANT: [esta peticion no pudo ejecutarse y quedo sin respuesta]"

HEARTBEAT_SECONDS = 10

IMPLEMENTATION_POLICY = """Implementation progress is displayed separately from your final answer.
For implementation requests, use todowrite BEFORE starting execution to create your own task-specific
plan. Choose the actual tasks needed for this request; never substitute a generic predefined list.
Keep that todo list updated while working: pending, in_progress, completed or cancelled.
Mark a task completed only after verifying its result. Leave blocked work pending or cancel it with
an explanation; never mark unsuccessful work completed. For ordinary questions, do not create todos.
Your final user-facing answer must be concise: outcome, remaining blockers, and a verified deployment
URL when applicable. Do not include intermediate narration, tool transcripts or internal reasoning.
This client cannot render interactive question forms. If clarification is needed, ask it in plain text
as your final answer and wait for the next chat message. Never call the question tool.
"""

# The checklist rides inside the text stream as a record-separator delimited JSON block. The
# Responses API has no checklist event, and the client accumulates text deltas into one message
# it can never rewrite, so the ticks have to travel out of band or they would end up baked into
# the answer. The client only sends this when it advertises the capability, so an older build
# never sees the raw blocks.
CONTROL = "\u001e"


def control(payload: dict) -> str:
    return f"{CONTROL}{json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}{CONTROL}"


def conversation_text(messages: list[dict[str, str]]) -> str:
    """A new session receives the bounded transcript supplied by the iOS client.

    Every user turn is closed before the next one opens, so a turn that never produced a reply
    is recorded as a dead turn rather than being read as an unfinished request.
    """
    blocks: list[str] = []
    for index, message in enumerate(messages):
        # Only a user turn that is IMMEDIATELY followed by another user turn was abandoned.
        # The final message is always the open request and must never be closed, or the model
        # has nothing left to answer.
        abandoned = (message["role"] == "user" and index + 1 < len(messages)
                     and messages[index + 1]["role"] == "user")
        if abandoned:
            blocks.append(f"USER: {message['content']}\n\n{FAILED_TURN}")
        else:
            blocks.append(f"{message['role'].upper()}: {message['content']}")
    return "\n\n".join(blocks)


def response_event(name: str, sequence: int, payload: dict) -> str:
    body = {"type": name, "sequence_number": sequence, **payload}
    return f"event: {name}\ndata: {json.dumps(body, ensure_ascii=False)}\n\n"


def final_text(result: dict) -> str:
    if result.get("info", {}).get("error"):
        raise ValueError("OpenCode reported a failed turn")
    parts = result.get("parts", [])
    # Narration before tools is progress, not the delivered answer.
    last_tool = max((i for i, part in enumerate(parts) if part.get("type") == "tool"), default=-1)
    return "".join(
        part.get("text", "") for part in parts[last_tool + 1:]
        if part.get("type") == "text" and not part.get("synthetic")
    )


def _failure_reason(exc: Exception) -> str:
    """A short, safe reason the phone can show. No paths, no upstream bodies, no secrets."""
    if isinstance(exc, httpx.ConnectError):
        # Almost always the OpenCode container being restarted, and the usual cause is its
        # memory limit: the agent's own baseline is ~500 MB of a 1 GB cap.
        return "El servicio super se reinicio. Vuelve a intentarlo en un momento."
    if isinstance(exc, httpx.ReadTimeout):
        return "La tarea tardo demasiado y se corto. Probalo de nuevo en pasos mas chicos."
    if isinstance(exc, httpx.HTTPStatusError):
        return f"Super mode fallo ({exc.response.status_code} del servicio)."
    if isinstance(exc, OSError):
        return "Super mode no esta configurado."
    return "Super mode no devolvio respuesta."


class Checklist:
    """Relay native OpenCode todos verbatim; the agent owns titles, order and status."""

    def __init__(self) -> None:
        self.todos = None

    def update(self, todos: list[dict]) -> list[str]:
        if not todos and self.todos is None:
            return []
        if todos == self.todos:
            return []
        self.todos = [dict(todo) for todo in todos]
        return [control({"k": "todos", "s": self.todos})]

    def finish(self, success: bool) -> list[str]:
        # Closing the transport cannot turn pending work into a completed task.
        return [control({"k": "end"})] if self.todos else []


class Activity:
    """Expose tool state, never raw arguments, command secrets or reasoning text."""

    def __init__(self) -> None:
        self.active: dict[str, tuple[str, str]] = {}
        self.last = None

    def emit(self, stage: str | None, detail: str = "") -> list[str]:
        value = (stage, detail)
        if value == self.last:
            return []
        self.last = value
        return [control({"k": "activity", "s": stage, "detail": detail})]

    @staticmethod
    def describe(tool: str, inputs: dict) -> tuple[str, str]:
        if tool in ("read", "write", "edit", "apply_patch"):
            path = str(inputs.get("filePath") or inputs.get("path") or "")
            name = Path(path).name
            # Even a filename can identify a credential. Never relay secret file names.
            if re.search(r"password|secret|token|\.env|\.pem|\.key", name, re.I):
                name = ""
            return ("reading" if tool == "read" else "editing", name[:80])
        if tool in ("glob", "grep", "websearch", "web_search"):
            return "searching", ""
        if tool == "webfetch":
            return "reading", (urlsplit(str(inputs.get("url") or "")).hostname or "")[:80]
        if tool == "skill":
            name = str(inputs.get("name") or "")
            return "loading_skill", name if SAFE_ID.fullmatch(name) else ""
        if tool == "todowrite":
            return "planning", ""
        if "engram" in tool:
            return "memory", ""
        if tool == "bash":
            try:
                words = shlex.split(str(inputs.get("command") or ""))
            except ValueError:
                words = []
            executable = Path(words[0]).name if words else ""
            # Only allow known executable names. The rest of the command, including every
            # argument and shell expansion, stays private and never reaches the phone.
            allowed = {"npm", "npx", "pnpm", "yarn", "bun", "python", "python3", "pytest",
                       "git", "docker", "node", "vercel", "go", "swift", "curl", "ls"}
            detail = executable if executable in allowed else ""
            if executable == "vercel" or (executable == "npx" and words[1:2] == ["vercel"]):
                if "deploy" in words or "--prod" in words:
                    return "deploying", "Vercel"
            if executable == "pytest" or (executable in {"npm", "pnpm", "yarn", "bun"}
                                           and words[1:2] == ["test"]):
                return "testing", detail
            return "running_command", detail
        return "working", ""

    def update(self, part: dict) -> list[str]:
        if part.get("type") == "tool":
            identity = part.get("id") or part.get("callID")
            if not identity:
                return []
            state = part.get("state") or {}
            if state.get("status") == "running":
                self.active[identity] = self.describe(part.get("tool", ""), state.get("input") or {})
            elif state.get("status") in ("completed", "error"):
                if identity not in self.active:
                    return []
                self.active.pop(identity)
            else:
                return []
            return self.emit(*next(reversed(self.active.values()))) if self.active else self.emit("waiting")
        if not self.active and part.get("type") in ("reasoning", "text"):
            return self.emit("thinking" if part["type"] == "reasoning" else "composing")
        return []


async def _pump(http: httpx.AsyncClient, auth: httpx.BasicAuth, session_id: str,
                queue: asyncio.Queue, checklist: Checklist | None, ready: asyncio.Event,
                activity: Activity | None = None) -> None:
    """Observe this session only. Text/tool output is deliberately not sent to the app."""
    try:
        async with http.stream("GET", f"{OPENCODE_URL}/event", auth=auth, timeout=None) as stream:
            stream.raise_for_status()
            ready.set()
            async for line in stream.aiter_lines():
                if not line.startswith("data: "):
                    continue
                try:
                    event = json.loads(line[6:])
                except ValueError:
                    continue
                properties = event.get("properties") or event.get("data") or {}
                part = properties.get("part") or {}
                if (properties.get("sessionID") or part.get("sessionID")) != session_id:
                    continue
                kind = event.get("type")
                if kind == "todo.updated" and checklist is not None:
                    for block in checklist.update(properties.get("todos", [])):
                        await queue.put(("progress", block))
                elif kind == "message.part.updated" and activity is not None:
                    for block in activity.update(part):
                        await queue.put(("progress", block))
                elif kind == "session.idle":
                    await queue.put(("idle", None))
                    return
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # a dropped event stream must not kill the turn
        await queue.put(("stream_error", exc))
    finally:
        ready.set()


async def abort(http: httpx.AsyncClient, auth: httpx.BasicAuth, session_id: str) -> bool:
    """Cancelling an HTTP request alone does not stop OpenCode's session execution."""
    try:
        result = await http.post(f"{OPENCODE_URL}/session/{session_id}/abort",
                                 auth=auth, timeout=10)
        result.raise_for_status()
        return True
    except httpx.HTTPError as exc:
        logger.warning("Could not abort OpenCode turn: %s", type(exc).__name__)
        return False


async def respond(http: httpx.AsyncClient, messages: list[dict[str, str]], system: str,
                  stream: bool, chat_id: str | None = None, caps: str = ""):
    """Only the gateway can reach OpenCode; never expose its HTTP API to the phone."""
    session_file = SESSION_DIR / f"{chat_id}.json" if chat_id and SAFE_ID.fullmatch(chat_id) else None
    dispatched = False
    try:
        password = PASSWORD_FILE.read_text(encoding="utf-8").strip()
        if not password:
            raise OSError("empty OpenCode password")
        auth = httpx.BasicAuth("opencode", password)
        state = None
        if session_file and session_file.exists():
            try:
                state = json.loads(session_file.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                pass
        # One chat, one OpenCode session, and never a neighbour's. The id lives in the chat's own
        # state file, so a fresh chat has no state to match and a different chat has a different
        # file: there is no path by which one conversation can inherit another's session.
        reuse = (isinstance(state, dict) and state.get("messages") == messages[:-1]
                  and isinstance(state.get("session_id"), str)
                  and SAFE_ID.fullmatch(state["session_id"]))
        if reuse:
            status = await http.get(f"{OPENCODE_URL}/session/status", auth=auth, timeout=10)
            status.raise_for_status()
            if status.json().get(state["session_id"], {}).get("type", "idle") != "idle":
                # The cached transcript records a completed answer. A still-running upstream
                # session is not safe to append to: rebuild only this chat from its transcript.
                session_file.unlink(missing_ok=True)
                if not await abort(http, auth, state["session_id"]):
                    raise ValueError("Could not stop stale OpenCode turn")
                reuse = False
        if reuse:
            session_id = state["session_id"]
        else:
            session = await http.post(
                f"{OPENCODE_URL}/session",
                json={"title": "Makima chat"}, auth=auth, timeout=15,
            )
            session.raise_for_status()
            session_id = session.json()["id"]
            if not isinstance(session_id, str) or not SAFE_ID.fullmatch(session_id):
                raise ValueError("Invalid OpenCode session ID")
        # Same framing on both paths. A reused session gets structured history from OpenCode
        # itself, so the user turn arrives bare and the model reads it differently than the
        # flattened transcript; prefixing "USER:" keeps the two paths behaving alike.
        payload = {
            "agent": "makima",
            "model": {"providerID": "opencode", "modelID": "space-bunny-free"},
            "variant": "high",
            "tools": {"question": False},
            "system": system + "\n\n" + IMPLEMENTATION_POLICY,
            "parts": [{"type": "text", "text": f"USER: {messages[-1]['content']}" if reuse else conversation_text(messages)}],
        }
        dispatched = True

        async def upstream():
            # No read timeout: an implementation may take as long as it takes. The stall guard
            # below only fires when the agent stops talking entirely.
            return await http.post(f"{OPENCODE_URL}/session/{session_id}/message",
                                   json=payload, auth=auth,
                                   timeout=httpx.Timeout(None, connect=10))

        if not stream:
            answer = await upstream()
            answer.raise_for_status()
            content = final_text(answer.json())
            if not content:
                raise ValueError("OpenCode returned no assistant text")
            content = await asyncio.to_thread(agenda.execute_reply, content, messages, chat_id)
            response_id, message_id = f"resp_{uuid4().hex}", f"msg_{uuid4().hex}"
            item = {"id": message_id, "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": content, "annotations": []}]}
            remember(session_file, session_id, messages, content)
            return {
                "id": response_id, "object": "response", "created_at": int(time.time()),
                "status": "completed", "model": "makima-super", "output": [item],
                "parallel_tool_calls": False, "tool_choice": "none", "tools": [], "metadata": {},
            }

        message_id = f"msg_{uuid4().hex}"
        common = {"item_id": message_id, "output_index": 0, "content_index": 0}
        # No keyword-based plan: only the agent can decide whether and how to plan a task.
        checklist = Checklist() if "checklist" in caps else None
        activity = Activity() if "activity" in caps.split(",") else None
        async def events():
            sequence = 0
            queue: asyncio.Queue = asyncio.Queue()
            ready = asyncio.Event()
            pump = asyncio.create_task(_pump(http, auth, session_id, queue, checklist, ready, activity))
            post = None
            getter = None
            completed = False
            try:
                # Subscribe before submitting the prompt so fast tool events cannot be lost.
                await ready.wait()
                if activity is not None:
                    for block in activity.emit("waiting"):
                        sequence += 1
                        yield response_event("response.output_text.delta", sequence,
                                             {**common, "delta": block})
                post = asyncio.create_task(upstream())
                getter = asyncio.create_task(queue.get())
                while not post.done() or not queue.empty() or getter.done():
                    done, _ = await asyncio.wait({post, getter}, timeout=HEARTBEAT_SECONDS,
                                                 return_when=asyncio.FIRST_COMPLETED)
                    if getter in done:
                        kind, value = getter.result()
                        getter = asyncio.create_task(queue.get())
                        if kind == "progress":
                            sequence += 1
                            yield response_event("response.output_text.delta", sequence,
                                                 {**common, "delta": value})
                        elif kind == "stream_error":
                            logger.warning("OpenCode progress unavailable: %s", type(value).__name__)
                    elif post in done:
                        break
                    else:
                        # SSE comments keep the transport alive without showing fake progress.
                        yield ": keep-alive\n\n"
                result = await post
                result.raise_for_status()
                content = final_text(result.json())
                if not content.strip():
                    raise ValueError("OpenCode returned no final answer")
                content = await asyncio.to_thread(agenda.execute_reply, content, messages, chat_id)
                if activity is not None:
                    for block in activity.emit(None):
                        sequence += 1
                        yield response_event("response.output_text.delta", sequence,
                                             {**common, "delta": block})
                if checklist is not None:
                    # Recover a last todo update if SSE delivery raced with request completion.
                    # This is the same agent-owned state, not an inferred/fabricated completion.
                    try:
                        todos = await http.get(f"{OPENCODE_URL}/session/{session_id}/todo",
                                               auth=auth, timeout=10)
                        todos.raise_for_status()
                        for block in checklist.update(todos.json()):
                            sequence += 1
                            yield response_event("response.output_text.delta", sequence,
                                                 {**common, "delta": block})
                    except (httpx.HTTPError, ValueError) as exc:
                        logger.warning("Could not refresh agent todos: %s", type(exc).__name__)
                    for block in checklist.finish(success=True):
                        sequence += 1
                        yield response_event("response.output_text.delta", sequence,
                                             {**common, "delta": block})
                # One final answer only. Never fall back to intermediate narration on failure.
                sequence += 1
                yield response_event("response.output_text.delta", sequence,
                                     {**common, "delta": content})
                remember(session_file, session_id, messages, content)
                completed = True
                yield response_event("response.output_text.done", sequence + 1,
                                     {**common, "text": content})
            except Exception as exc:
                if session_file:
                    session_file.unlink(missing_ok=True)
                logger.error("OpenCode response failed: %s: %s", type(exc).__name__, exc)
                if activity is not None:
                    for block in activity.emit(None):
                        sequence += 1
                        yield response_event("response.output_text.delta", sequence,
                                             {**common, "delta": block})
                if checklist is not None:
                    for block in checklist.finish(success=False):
                        sequence += 1
                        yield response_event("response.output_text.delta", sequence,
                                             {**common, "delta": block})
                sequence += 1
                yield response_event("error", sequence, {"code": "super_unavailable",
                                     "message": _failure_reason(exc), "param": None})
            finally:
                # Closing the app's stream must not leak subscriptions or background requests.
                # Starlette cancels the enclosing AnyIO scope on disconnect. Shield cleanup
                # so cancellation cannot interrupt the abort and leave an invisible tool running.
                with CancelScope(shield=True):
                    tasks = [task for task in (pump, post, getter) if task is not None]
                    for task in tasks:
                        if not task.done():
                            task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    if post is not None and not completed:
                        if session_file:
                            session_file.unlink(missing_ok=True)
                        await abort(http, auth, session_id)

        return StreamingResponse(
            events(), media_type="text/event-stream",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )
    except asyncio.CancelledError:
        if dispatched:
            with CancelScope(shield=True):
                if session_file:
                    session_file.unlink(missing_ok=True)
                await abort(http, auth, session_id)
        raise
    except (OSError, ValueError, KeyError, httpx.HTTPError) as exc:
        # Once the message POST left this process, OpenCode has already appended the user turn
        # and whatever tool calls completed to that session, even though we never got an answer.
        # Reusing it next time would replay a half-finished turn, so drop the cached pointer and
        # let the next request rebuild from the client's transcript.
        if dispatched and session_file:
            session_file.unlink(missing_ok=True)
        if dispatched:
            await abort(http, auth, session_id)
        logger.error("OpenCode response failed: %s: %s", type(exc).__name__, exc)
        raise HTTPException(503, _failure_reason(exc)) from exc


def remember(session_file: Path | None, session_id: str, messages: list[dict[str, str]],
             content: str) -> None:
    if not session_file:
        return
    SESSION_DIR.mkdir(parents=True, exist_ok=True)
    temporary = session_file.with_suffix(".tmp")
    temporary.write_text(json.dumps({
        "session_id": session_id,
        "messages": [*messages, {"role": "assistant", "content": content}],
    }, ensure_ascii=False), encoding="utf-8")
    temporary.replace(session_file)
