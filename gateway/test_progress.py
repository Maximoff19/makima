import asyncio
import json

import httpx
import pytest
import anyio

import opencode_bridge as bridge


def events_from(body):
    return [json.loads(line[6:]) for line in body.splitlines() if line.startswith("data: ")]


def test_activity_uses_real_tool_state_and_never_relays_sensitive_arguments():
    activity = bridge.Activity()

    def tool(identity, name, status, inputs=None):
        return {"id": identity, "type": "tool", "tool": name,
                "state": {"status": status, "input": inputs or {}}}

    def values(blocks):
        return [json.loads(block.strip(bridge.CONTROL)) for block in blocks]

    read = tool("read-1", "read", "running", {"filePath": "/workspace/project/agenda.py"})
    assert values(activity.update(read)) == [{"k": "activity", "s": "reading", "detail": "agenda.py"}]
    assert activity.update(read) == [], "Repeated updates must not flood the stream"
    assert activity.update({"type": "reasoning", "text": "Private reasoning"}) == []
    command = tool("cmd-1", "bash", "running", {"command": "npm run build --token PRIVATE_TOKEN"})
    blocks = activity.update(command)
    assert values(blocks)[0] == {"k": "activity", "s": "running_command", "detail": "npm"}
    assert "PRIVATE_TOKEN" not in "".join(blocks)
    assert values(activity.update(tool("cmd-1", "bash", "completed")))[0]["s"] == "reading"
    assert values(activity.update(tool("read-1", "read", "completed")))[0]["s"] == "waiting"
    assert values(activity.update({"type": "reasoning", "text": "Private reasoning"}))[0]["s"] == "thinking"
    assert bridge.Activity.describe("read", {"filePath": "/run/secrets/opencode_password"}) == ("reading", "")
    assert bridge.Activity.describe("webfetch", {"url": "https://user:password@example.com/a?token=secret"}) == ("reading", "example.com")
    assert bridge.Activity.describe("bash", {"command": "npx vercel deploy --token SECRET"}) == ("deploying", "Vercel")
    assert bridge.Activity.describe("bash", {"command": "echo vercel deploy"}) == ("running_command", "")


@pytest.mark.parametrize("caps", ["checklist,activity", "checklist"])
def test_stream_relays_nested_tool_activity_only_to_capable_clients(configured_bridge, caps):
    def part_event(session, kind, **extra):
        part = {"id": "part-1", "sessionID": session, "type": kind, **extra}
        return "data: " + json.dumps({"type": "message.part.updated", "properties": {"part": part}}) + "\n\n"

    async def backend(request):
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-activity"})
        if request.url.path == "/event":
            return httpx.Response(200, text=(
                part_event("oc-activity", "tool", tool="read", state={"status": "running", "input": {"filePath": "/workspace/agenda.py"}})
                + part_event("other-chat", "tool", tool="read", state={"status": "running", "input": {"filePath": "/workspace/neighbor.py"}})
                + part_event("oc-activity", "tool", tool="read", state={"status": "completed"})
                + part_event("oc-activity", "reasoning", text="Private reasoning")))
        if request.url.path.endswith("/todo"):
            return httpx.Response(200, json=[])
        if request.url.path.endswith("/message"):
            await asyncio.sleep(0.01)
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "Final answer"}]})
        raise AssertionError(request.url)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            response = await bridge.respond(client, [{"role": "user", "content": "Read a file"}],
                                            "", True, "activity-chat", caps)
            body = "".join([chunk async for chunk in response.body_iterator])
        events = events_from(body)
        deltas = [e["delta"] for e in events if e["type"] == "response.output_text.delta"]
        payloads = [json.loads(d.strip(bridge.CONTROL)) for d in deltas if d.startswith(bridge.CONTROL)]
        if "activity" in caps:
            assert any(p.get("s") == "reading" and p["detail"] == "agenda.py" for p in payloads)
            assert any(p.get("s") == "thinking" for p in payloads)
            assert payloads[-1]["s"] is None
        else:
            assert payloads == []
        assert "Private reasoning" not in body
        assert "neighbor.py" not in body
        assert deltas[-1] == "Final answer"
        assert events[-1]["type"] == "response.output_text.done"
    asyncio.run(run())


@pytest.fixture
def configured_bridge(monkeypatch, tmp_path):
    password = tmp_path / "password"
    password.write_text("test-password")
    monkeypatch.setattr(bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(bridge, "SESSION_DIR", tmp_path / "sessions")


def test_agent_todos_keep_their_exact_status_at_stream_end():
    progress = bridge.Checklist()
    todos = [
        {"content": "Inspect pet shop", "status": "completed", "priority": "medium"},
        {"content": "Resolve deployment credentials", "status": "pending", "priority": "high"},
    ]
    blocks = progress.update(todos) + progress.finish(False)
    payloads = [json.loads(block.strip(bridge.CONTROL)) for block in blocks]
    assert payloads == [{"k": "todos", "s": todos}, {"k": "end"}]
    assert progress.todos[1]["status"] == "pending"
    assert progress.update(todos) == []


def test_silent_event_stream_does_not_hide_a_failed_request(configured_bridge):
    class SilentStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            await asyncio.sleep(60)
            yield b""

    async def backend(request):
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-error"})
        if request.url.path == "/event":
            return httpx.Response(200, stream=SilentStream())
        return httpx.Response(502)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            response = await bridge.respond(client, [{"role": "user", "content": "Create a React app"}],
                                            "", True, "error-chat", "checklist")
            async def collect():
                return "".join([chunk async for chunk in response.body_iterator])
            body = await asyncio.wait_for(collect(), timeout=1)
            events = events_from(body)
            assert events[-1]["type"] == "error"
            assert not any(event["type"] == "response.output_text.done" for event in events)
            assert "502" in events[-1]["message"]
    asyncio.run(run())


def test_disconnect_cancel_scope_still_finishes_abort(configured_bridge):
    started = asyncio.Event()
    aborted = asyncio.Event()

    class SilentStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            await asyncio.sleep(60)
            yield b""

    async def backend(request):
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-disconnect"})
        if request.url.path == "/event":
            return httpx.Response(200, stream=SilentStream())
        if request.url.path.endswith("/message"):
            started.set()
            await asyncio.sleep(60)
        if request.url.path.endswith("/abort"):
            await asyncio.sleep(0.01)
            aborted.set()
            return httpx.Response(200, json=True)
        raise AssertionError(request.url)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            response = await bridge.respond(client, [{"role": "user", "content": "Build an app"}],
                                            "", True, "disconnect-chat")
            async with anyio.create_task_group() as group:
                async def collect():
                    async for _ in response.body_iterator:
                        pass
                group.start_soon(collect)
                await asyncio.wait_for(started.wait(), timeout=1)
                group.cancel_scope.cancel()
            assert aborted.is_set()
            assert not (bridge.SESSION_DIR / "disconnect-chat.json").exists()
    asyncio.run(run())


@pytest.mark.parametrize("stream", [False, True])
def test_cancelled_turn_aborts_upstream_and_invalidates_cache(configured_bridge, stream):
    started = asyncio.Event()
    aborted = []
    messages = [{"role": "user", "content": "Hello"}]
    bridge.remember(bridge.SESSION_DIR / "cancel-chat.json", "oc-cancel", messages, "Hi")
    followup = [*messages, {"role": "assistant", "content": "Hi"},
                {"role": "user", "content": "Build an app"}]

    class SilentStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            await asyncio.sleep(60)
            yield b""

    async def backend(request):
        if request.url.path == "/session/status":
            return httpx.Response(200, json={})
        if request.url.path == "/event":
            return httpx.Response(200, stream=SilentStream())
        if request.url.path.endswith("/abort"):
            aborted.append(request.url.path)
            return httpx.Response(200, json=True)
        if request.url.path.endswith("/message"):
            started.set()
            await asyncio.sleep(60)
        raise AssertionError(request.url)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            async def turn():
                response = await bridge.respond(client, followup, "", stream, "cancel-chat")
                if stream:
                    async for _ in response.body_iterator:
                        pass
            task = asyncio.create_task(turn())
            await asyncio.wait_for(started.wait(), timeout=1)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
        assert aborted == ["/session/oc-cancel/abort"]
        assert not (bridge.SESSION_DIR / "cancel-chat.json").exists()
    asyncio.run(run())


def test_busy_cached_session_is_aborted_before_rebuilding(configured_bridge):
    messages = [{"role": "user", "content": "Hello"}]
    bridge.remember(bridge.SESSION_DIR / "busy-chat.json", "oc-busy", messages, "Hi")
    bridge.remember(bridge.SESSION_DIR / "other-chat.json", "oc-other", messages, "Hi")
    followup = [*messages, {"role": "assistant", "content": "Hi"},
                {"role": "user", "content": "Another question"}]
    paths = []

    async def backend(request):
        paths.append(request.url.path)
        if request.url.path == "/session/status":
            return httpx.Response(200, json={"oc-busy": {"type": "busy"},
                                             "oc-other": {"type": "busy"}})
        if request.url.path == "/session/oc-busy/abort":
            return httpx.Response(200, json=True)
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-new"})
        if request.url.path == "/session/oc-new/message":
            payload = json.loads(request.content)
            assert payload["tools"] == {"question": False}
            assert payload["parts"][0]["text"] == bridge.conversation_text(followup)
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "Answer"}]})
        raise AssertionError(request.url)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            response = await bridge.respond(client, followup, "", False, "busy-chat")
            assert response["output"][0]["content"][0]["text"] == "Answer"
        assert paths == ["/session/status", "/session/oc-busy/abort", "/session",
                         "/session/oc-new/message"]
        assert json.loads((bridge.SESSION_DIR / "busy-chat.json").read_text())["session_id"] == "oc-new"
        assert (bridge.SESSION_DIR / "other-chat.json").exists()
    asyncio.run(run())


def test_failed_final_answer_does_not_replay_intermediate_text(configured_bridge):
    async def backend(request):
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-failed"})
        if request.url.path == "/event":
            event = {"type": "message.part.delta", "properties": {
                "sessionID": "oc-failed", "field": "text", "delta": "Secret tool narration"}}
            return httpx.Response(200, text=f"data: {json.dumps(event)}\n\n")
        return httpx.Response(200, json={"info": {"error": {"name": "ProviderError"}}, "parts": []})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            response = await bridge.respond(client, [{"role": "user", "content": "Create a React app"}],
                                            "", True, "failed-chat", "checklist")
            body = "".join([chunk async for chunk in response.body_iterator])
            assert "Secret tool narration" not in body
            assert events_from(body)[-1]["type"] == "error"
            assert not (bridge.SESSION_DIR / "failed-chat.json").exists()
    asyncio.run(run())


def test_active_long_request_has_no_read_deadline(configured_bridge, monkeypatch):
    monkeypatch.setattr(bridge, "HEARTBEAT_SECONDS", 0.01)
    seen = []

    class SilentStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            await asyncio.sleep(60)
            yield b""

    async def backend(request):
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-long"})
        if request.url.path == "/event":
            return httpx.Response(200, stream=SilentStream())
        if request.url.path.endswith("/todo"):
            return httpx.Response(200, json=[])
        assert request.extensions["timeout"]["read"] is None
        await asyncio.sleep(0.05)
        return httpx.Response(200, json={"parts": [{"type": "text", "text": "Final answer"}]})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as client:
            response = await bridge.respond(client, [{"role": "user", "content": "Create a React app"}],
                                            "", True, "long-chat", "checklist")
            async for chunk in response.body_iterator:
                seen.append(chunk)
        assert any(chunk.startswith(": keep-alive") for chunk in seen)
        assert events_from("".join(seen))[-1]["type"] == "response.output_text.done"
    asyncio.run(run())
