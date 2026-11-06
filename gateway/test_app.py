import asyncio
import io
import json
import wave

import httpx
import pytest
from fastapi import HTTPException

import app as gateway
import opencode_bridge
import agenda

from app import ThinkFilter, app, memory_candidate, messages_from_input


@pytest.fixture(autouse=True)
def isolated_agenda(monkeypatch, tmp_path):
    monkeypatch.setattr(agenda, "DB_PATH", tmp_path / "agenda.sqlite3")
    monkeypatch.setattr(gateway, "_MODEL_CAPABILITIES", {gateway.MODEL: {"completion", "tools"}})


def test_chat_deletion_is_authenticated_and_blocks_delayed_upload(monkeypatch, tmp_path):
    monkeypatch.setattr(gateway, "HISTORY_DIR", tmp_path)
    gateway._history_file("chat-1").write_text(json.dumps({"id": "chat-1", "transcript": ["Hello"]}))

    async def run():
        app.state.token = "x" * 64
        headers = {"Authorization": "Bearer " + "x" * 64}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            assert (await client.delete("/v1/history/chat-1")).status_code == 401
            assert (await client.delete("/v1/history/chat.bad", headers=headers)).status_code == 400
            assert (await client.delete("/v1/history/chat-1", headers=headers)).status_code == 204
            assert (await client.get("/v1/history", headers=headers)).json() == []
            assert (await client.post("/v1/history", headers=headers,
                                      json={"id": "chat-1", "transcript": ["Delayed upload"]})).json() == {"stored": False}
            assert (await client.delete("/v1/history/chat-1", headers=headers)).status_code == 204
    asyncio.run(run())


def test_memory_selection_and_input_validation():
    assert memory_candidate("Makima, recuerda que mi proyecto Atlas utiliza Go y PostgreSQL.") == "mi proyecto Atlas utiliza Go y PostgreSQL"
    assert memory_candidate("recuerda que mi contraseña es hunter2") is None
    assert memory_candidate("¿Cuánto es 25 por 4?") is None
    assert memory_candidate("¿Qué tecnologías utiliza Atlas?") is None
    assert messages_from_input([{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Hola"}]}]) == ([{"role": "user", "content": "Hola"}], [])


def test_model_capabilities_are_checked_and_cached(monkeypatch):
    monkeypatch.setattr(gateway, "_MODEL_CAPABILITIES", {})
    seen = []

    def backend(request):
        seen.append(request.url.path)
        assert request.url.path == "/api/show"
        return httpx.Response(200, json={"capabilities": ["completion", "vision"]})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as http:
            assert await gateway.model_capabilities(http, "vision-model") == {"completion", "vision"}
            assert await gateway.model_capabilities(http, "vision-model") == {"completion", "vision"}
        assert seen == ["/api/show"]
    asyncio.run(run())


def test_normal_vision_receives_images_directly_without_unsupported_tools(monkeypatch):
    monkeypatch.setattr(gateway, "_MODEL_CAPABILITIES", {gateway.MODEL: {"completion", "vision"}})
    monkeypatch.setattr(gateway, "PROMPT_PATH", gateway.Path(__file__).resolve().parent.parent / "config/system-prompt.txt")
    searches = []

    async def search(http, query):
        searches.append(query)
        return "Verified search result"

    monkeypatch.setattr(gateway, "web_search", search)

    def backend(request):
        if request.url.path == "/sessions":
            return httpx.Response(200, json={})
        if request.url.path in ("/search", "/observations"):
            return httpx.Response(200, json=[])
        if request.url.path == "/api/chat":
            payload = json.loads(request.content)
            assert payload["model"] == gateway.MODEL
            assert payload["messages"][-1]["images"] == ["encoded-test-image"]
            assert "Verified search result" in payload["messages"][0]["content"]
            assert "tools" not in payload, "Qwen2.5-VL rejects tool schemas with HTTP 400"
            return httpx.Response(200, text=json.dumps({"message": {"content": "Green"}, "done": True}) + "\n")
        raise AssertionError(f"Unexpected image-caption service or tool request: {request.url}")

    async def run():
        app.state.token = "x" * 64
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as upstream:
            app.state.http = upstream
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
                response = await client.post("/v1/responses", headers={"Authorization": "Bearer " + "x" * 64},
                    json={"model": "makima", "input": [{"role": "user", "content": [
                        {"type": "input_text", "text": "Busca el color de esta imagen"},
                        {"type": "input_image", "image_url": "data:image/png;base64,encoded-test-image"}]}]})
                assert response.status_code == 200, response.text
                assert response.json()["output"][0]["content"][0]["text"] == "Green"
                assert searches == ["Busca el color de esta imagen"]
    asyncio.run(run())


def test_fast_model_accepts_ollama_dictionary_tool_arguments(monkeypatch):
    model = "qwen2.5:7b-instruct-q4_K_M"
    monkeypatch.setattr(gateway, "FAST_MODEL", model)
    monkeypatch.setattr(gateway, "_MODEL_CAPABILITIES", {model: {"completion", "tools"}})
    monkeypatch.setattr(gateway, "PROMPT_PATH", gateway.Path(__file__).resolve().parent.parent / "config/system-prompt.txt")
    calls = []

    async def dispatch(http, name, arguments, question):
        assert name == "web_search"
        assert arguments == {"query": "test query"}
        return "Search result"

    monkeypatch.setattr(gateway.toolregistry, "dispatch", dispatch)

    def backend(request):
        if request.url.path == "/sessions":
            return httpx.Response(200, json={})
        if request.url.path in ("/search", "/observations"):
            return httpx.Response(200, json=[])
        if request.url.path == "/api/chat":
            payload = json.loads(request.content)
            calls.append(payload)
            assert payload["model"] == model
            if len(calls) == 1:
                assert payload["tools"]
                message = {"content": "", "tool_calls": [{"function": {
                    "name": "web_search", "arguments": {"query": "test query"}}}]}
            else:
                assert payload["messages"][-1]["role"] == "tool"
                message = {"content": "Found it"}
            return httpx.Response(200, text=json.dumps({"message": message, "done": True}) + "\n")
        raise AssertionError(request.url)

    async def run():
        app.state.token = "x" * 64
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as upstream:
            app.state.http = upstream
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
                response = await client.post("/v1/responses", headers={"Authorization": "Bearer " + "x" * 64},
                    json={"model": "makima-fast", "input": "Busca algo"})
                assert response.status_code == 200, response.text
                assert response.json()["output"][0]["content"][0]["text"] == "Found it"
        assert len(calls) == 2
    asyncio.run(run())


def test_private_gateway_and_memory_across_conversations(monkeypatch):
    monkeypatch.setattr(gateway, "PROMPT_PATH", gateway.Path(__file__).resolve().parent.parent / "config/system-prompt.txt")
    saved = []

    def backend(request: httpx.Request):
        if request.url.path == "/search":
            term = request.url.params.get("q", "")
            return httpx.Response(200, json=[{"id": i, "content": text} for i, text in enumerate(saved, 1) if term in text.lower()])
        if request.url.path == "/sessions":
            return httpx.Response(200, json={"id": "session"})
        if request.url.path == "/observations":
            if request.method == "GET":
                return httpx.Response(200, json=[])
            saved.append(json.loads(request.content)["content"])
            return httpx.Response(200, json={"id": len(saved)})
        if request.url.path == "/api/chat":
            system = json.loads(request.content)["messages"][0]["content"]
            text = "Go y PostgreSQL" if "Atlas utiliza Go y PostgreSQL" in system else "Entendido"
            return httpx.Response(200, text=json.dumps({"message": {"content": text}, "done": False}) + "\n" + json.dumps({"message": {"content": ""}, "done": True}) + "\n")
        if request.url.path == "/v1/audio/speech":
            assert json.loads(request.content)["voice"] == "bf_emma"  # sweetest Kokoro preset
            return httpx.Response(200, content=b"mp3")
        raise AssertionError(request.url)

    async def run():
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            assert (await client.post("/v1/responses", json={"input": "Hola"})).status_code == 401
            assert (await client.get("/v1/history")).status_code == 401
            assert (await client.post("/v1/history", json={"id": "chat"})).status_code == 401
            headers = {"Authorization": "Bearer " + "x" * 64}
            first = await client.post("/v1/responses", headers=headers, json={"model": "makima", "input": "Makima, recuerda que mi proyecto Atlas utiliza Go y PostgreSQL."})
            assert first.status_code == 200
            assert saved == ["mi proyecto Atlas utiliza Go y PostgreSQL"]
            second = await client.post("/v1/responses", headers=headers, json={"model": "makima", "input": "¿Mi proyecto Atlas utiliza Go y PostgreSQL?", "stream": True})
            assert second.status_code == 200
            assert '"delta": "Go y PostgreSQL"' in second.text
            assert '"type": "response.output_text.delta"' in second.text
            assert '"sequence_number": 1' in second.text
            assert saved == ["mi proyecto Atlas utiliza Go y PostgreSQL"]
            assert (await client.post("/v1/responses", headers=headers, json={"model": "makima", "input": "Hi", "tools": [{"type": "web_search_preview"}]})).status_code == 400
            assert (await client.post("/v1/audio/transcriptions", headers=headers, files={"file": ("unknown.exe", b"abc")})).status_code == 400
            speech = await client.post("/v1/audio/speech", headers=headers, json={"model": "makima-voice", "voice": "makima", "input": "Hola."})
            assert speech.content == b"mp3" and speech.headers["content-type"] == "audio/mpeg"
        await app.state.http.aclose()

    asyncio.run(run())


def test_super_mode_uses_private_opencode_makima_agent(monkeypatch, tmp_path):
    password = tmp_path / "opencode-password"
    password.write_text("private-test-password", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", tmp_path / "sessions")
    monkeypatch.setattr(gateway, "PROMPT_PATH", gateway.Path(__file__).resolve().parent.parent / "config/system-prompt.txt")
    monkeypatch.setattr(gateway, "_CORE_CACHE", None)
    calls = []

    def backend(request: httpx.Request):
        if request.url.path == "/sessions":
            return httpx.Response(200, json={"id": "memory-session"})
        if request.url.path in ("/search", "/observations"):
            return httpx.Response(200, json=[])
        if request.url.path == "/session/status":
            return httpx.Response(200, json={})
        if request.url.path == "/session":
            assert request.headers["authorization"].startswith("Basic ")
            calls.append("session-created")
            return httpx.Response(200, json={"id": "oc-session"})
        if request.url.path == "/session/oc-session/message":
            body = json.loads(request.content)
            calls.append(body)
            assert body["model"] == {"providerID": "opencode", "modelID": "space-bunny-free"}
            assert body["variant"] == "high"
            # Preserve the agent's tools except interactive questions, which the phone cannot
            # render. Clarifications must be delivered as ordinary assistant text.
            assert body["agent"] == "makima"
            assert body["tools"] == {"question": False}
            assert "plain text" in body["system"]
            assert gateway.PROMPT_PATH.read_text(encoding="utf-8") not in body["system"]
            assert "Personal agenda protocol" in body["system"]
            if len([call for call in calls if isinstance(call, dict)]) == 1:
                assert "USER: Hola" in body["parts"][0]["text"]
                return httpx.Response(200, json={"parts": [{"type": "text", "text": "Hola desde Makima"}]})
            # The reused session already holds structured history, so the user turn goes in with
            # the same "USER:" framing the rebuilt-transcript path uses. Same format both paths.
            assert body["parts"][0]["text"] == "USER: Otra pregunta"
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "Otra respuesta"}]})
        raise AssertionError(f"Unexpected upstream request: {request.url}")

    async def run():
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            assert (await client.post("/v1/responses", json={"model": "makima-super", "input": "Hola"})).status_code == 401
            headers = {"Authorization": "Bearer " + "x" * 64}
            first_input = [{"role": "user", "content": "Hola"}]
            response = await client.post("/v1/responses", headers=headers, json={"model": "makima-super", "input": first_input, "metadata": {"chat_id": "chat-1"}, "stream": True})
            assert response.status_code == 200, response.text
            assert '"delta": "Hola desde Makima"' in response.text
            assert '"type": "response.output_text.done"' in response.text
            next_input = [*first_input, {"role": "assistant", "content": "Hola desde Makima"}, {"role": "user", "content": "Otra pregunta"}]
            plain = await client.post("/v1/responses", headers=headers, json={"model": "makima-super", "input": next_input, "metadata": {"chat_id": "chat-1"}})
            assert plain.json()["output"][0]["content"][0]["text"] == "Otra respuesta"
            assert len([call for call in calls if call == "session-created"]) == 1
            assert opencode_bridge.SESSION_DIR.joinpath("chat-1.json").exists()
        await app.state.http.aclose()

    asyncio.run(run())


def test_failed_turn_does_not_swallow_the_next_request(monkeypatch, tmp_path):
    """A turn the gateway could not answer stays in the client transcript as a bare USER message.

    The phone keeps the user's text and only attaches an error flag it never sends, so without
    an explicit close the transcript ends in two adjacent USER turns and the model answers the
    abandoned task instead of the newest message.
    """
    messages = [
        {"role": "user", "content": "Hola"},
        {"role": "assistant", "content": "Hola"},
        {"role": "user", "content": "Creá la carta y publicala"},
        {"role": "user", "content": "hola de nuevo"},
    ]
    text = opencode_bridge.conversation_text(messages)
    assert "USER: Creá la carta y publicala\n\nASSISTANT: [esta peticion no pudo ejecutarse" in text
    assert text.endswith("USER: hola de nuevo")
    # The last message is the only turn left open.
    assert text.count("[esta peticion no pudo ejecutarse y quedo sin respuesta]") == 1
    # A clean transcript is untouched: no marker is invented where nothing failed.
    clean = [{"role": "user", "content": "Hola"}, {"role": "assistant", "content": "Hola"}]
    assert opencode_bridge.conversation_text(clean) == "USER: Hola\n\nASSISTANT: Hola"


def test_failed_super_turn_drops_the_session_so_the_next_one_rebuilds(monkeypatch, tmp_path):
    """A dispatched turn can leave the OpenCode session dirty even when we never got an answer."""
    password = tmp_path / "opencode-password"
    password.write_text("private-test-password", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    sessions = tmp_path / "sessions"
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", sessions)
    created = []

    def backend(request: httpx.Request):
        if request.url.path == "/session":
            created.append("session")
            return httpx.Response(200, json={"id": f"oc-{len(created)}"})
        if request.url.path.endswith("/abort"):
            return httpx.Response(200, json=True)
        if request.url.path.endswith("/message"):
            # First call times out mid-run, as a long tool chain does.
            if len([url for url in seen if url.endswith("/message")]) == 1:
                return httpx.Response(504)
            # Second call answers normally.
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "Respuesta"}]})
        raise AssertionError(request.url)

    seen: list[str] = []
    transport = httpx.MockTransport(lambda request: (seen.append(str(request.url)), backend(request))[1])
    messages = [{"role": "user", "content": "Hola"}]

    async def run():
        http = httpx.AsyncClient(transport=transport)
        with pytest.raises(HTTPException) as failed:
            await opencode_bridge.respond(http, messages, "", False, "chat-x")
        assert failed.value.status_code == 503
        assert any(url.endswith("/session/oc-1/abort") for url in seen)
        # The stale session pointer must be gone, not left pointing at a half-run session.
        assert not sessions.joinpath("chat-x.json").exists()
        ok = await opencode_bridge.respond(http, messages, "", False, "chat-x")
        assert ok["output"][0]["content"][0]["text"] == "Respuesta"
        assert len(created) == 2, "the retry must build a fresh session"
        await http.aclose()

    asyncio.run(run())


def test_super_returns_only_the_final_answer_not_agent_narration(monkeypatch, tmp_path):
    """Progress and intermediate narration must never be appended to the delivered answer."""
    password = tmp_path / "opencode-password"
    password.write_text("pw", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", tmp_path / "sessions")

    def event(kind, **props):
        return f"data: {json.dumps({'type': kind, 'properties': {'sessionID': 'oc-ses', **props}})}\n\n"

    def backend(request: httpx.Request):
        if request.url.path == "/sessions":
            return httpx.Response(200, json={"id": "memory-session"})
        if request.url.path in ("/search", "/observations"):
            return httpx.Response(200, json=[])
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-ses"})
        if request.url.path == "/event":
            body = (event("message.part.delta", field="text", delta="Voy a ")
                    + event("message.part.delta", field="text", delta="crear el proyecto.")
                    # Another session's delta must be ignored, not shown as our own progress.
                    + f'data: {json.dumps({"type": "message.part.delta", "properties": {"sessionID": "otro", "delta": "ruido"}})}\n\n'
                    + event("session.idle"))
            return httpx.Response(200, text=body, headers={"content-type": "text/event-stream"})
        if request.url.path.endswith("/message"):
            return httpx.Response(200, json={"parts": [
                {"type": "text", "text": "Voy a crear el proyecto."},
                {"type": "tool", "tool": "write"},
                {"type": "text", "text": "Published: https://example.com/project"},
            ]})
        raise AssertionError(f"Unexpected upstream request: {request.url}")

    async def run():
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            response = await client.post("/v1/responses", headers={"Authorization": "Bearer " + "x" * 64},
                json={"model": "makima-super", "input": [{"role": "user", "content": "Crea el proyecto"}],
                      "metadata": {"chat_id": "chat-stream"}, "stream": True})
            assert response.status_code == 200, response.text
            assert sse_deltas(response.text) == ["Published: https://example.com/project"]
            assert "Voy a" not in response.text
            assert "ruido" not in response.text
            assert '"type": "response.output_text.done"' in response.text
            assert "https://example.com/project" in response.text
        await app.state.http.aclose()

    asyncio.run(run())


def test_super_reports_a_dead_opencode_container_instead_of_a_bare_error(monkeypatch, tmp_path):
    """An OOM-killed container shows up as ConnectError. Say that, not "no response"."""
    password = tmp_path / "opencode-password"
    password.write_text("pw", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", tmp_path / "sessions")

    def backend(request: httpx.Request):
        if request.url.path in ("/sessions", "/search", "/observations"):
            return httpx.Response(200, json={} if request.url.path == "/sessions" else [])
        raise httpx.ConnectError("connection refused")

    async def run():
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            response = await client.post("/v1/responses", headers={"Authorization": "Bearer " + "x" * 64},
                json={"model": "makima-super", "input": "Hola"})
            assert response.status_code == 503
            assert "reinicio" in response.json()["detail"]
        await app.state.http.aclose()

    asyncio.run(run())


def sse_deltas(body: str) -> list[str]:
    """Read the SSE stream the way a client does: parse each data line, unescape the payload.

    Asserting on the raw text is misleading here. JSON escapes the record separator, so the wire
    carries the six characters \\u001e and only becomes the real character after decoding.
    """
    out = []
    for line in body.splitlines():
        if not line.startswith("data: "):
            continue
        event = json.loads(line[6:])
        if event.get("type") == "response.output_text.delta":
            out.append(event["delta"])
    return out


def _tool_event(tool: str, status: str = "completed") -> str:
    part = {"type": "tool", "tool": tool, "state": {"status": status, "input": {}}}
    return f"data: {json.dumps({'type': 'message.part.updated', 'properties': {'sessionID': 'oc-ses', 'part': part}})}\n\n"


def test_implementation_streams_a_live_checklist(monkeypatch, tmp_path):
    """An implementation must show its steps ticking as the agent works.

    The ticks are control blocks riding the text stream, because the client folds text deltas
    into one string it can never rewrite. They must appear, they must stay out of the answer,
    and they must only go to a client that advertised the capability.
    """
    password = tmp_path / "opencode-password"
    password.write_text("pw", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", tmp_path / "sessions")
    titles = ["Inspect existing pet shop components", "Build product catalog", "Deploy storefront"]

    def todos(statuses):
        return [{"content": title, "status": state, "priority": "high"}
                for title, state in zip(titles, statuses)]

    def todo_event(statuses):
        return "data: " + json.dumps({"type": "todo.updated", "properties": {
            "sessionID": "oc-ses", "todos": todos(statuses)}}) + "\n\n"

    def backend(request: httpx.Request):
        if request.url.path in ("/sessions", "/search", "/observations"):
            return httpx.Response(200, json={} if request.url.path == "/sessions" else [])
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-ses"})
        if request.url.path == "/event":
            body = (todo_event(["pending", "pending", "pending"])
                    + todo_event(["completed", "in_progress", "pending"])
                    + todo_event(["completed", "completed", "completed"])
                    + 'data: ' + json.dumps({"type": "session.idle", "properties": {"sessionID": "oc-ses"}}) + "\n\n")
            return httpx.Response(200, text=body, headers={"content-type": "text/event-stream"})
        if request.url.path.endswith("/todo"):
            return httpx.Response(200, json=todos(["completed"] * 3))
        if request.url.path.endswith("/message"):
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "Listo, deployed."}]})
        raise AssertionError(request.url)

    async def ask(content: str, caps: str | None):
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            body = {"model": "makima-super", "input": [{"role": "user", "content": content}],
                    "metadata": {"chat_id": "c1"}, "stream": True}
            if caps is not None:
                body["metadata"]["caps"] = caps
            return await client.post("/v1/responses", headers={"Authorization": "Bearer " + "x" * 64}, json=body)

    async def run():
        # An implementation, with a capable client: the plan and the ticks must both go out.
        response = await ask("Creame una landing page en React y desplegala", "checklist")
        assert response.status_code == 200, response.text
        deltas = sse_deltas(response.text)
        joined = "".join(deltas)
        control = opencode_bridge.CONTROL
        snapshots = [json.loads(delta.strip(control)) for delta in deltas if delta.startswith(control)]
        snapshots = [p["s"] for p in snapshots if p["k"] == "todos"]
        assert [todo["content"] for todo in snapshots[0]] == titles
        assert [todo["status"] for todo in snapshots[0]] == ["pending"] * 3
        assert [todo["status"] for todo in snapshots[1]] == ["completed", "in_progress", "pending"]
        assert [todo["status"] for todo in snapshots[-1]] == ["completed"] * 3
        assert f'{control}{{"k":"end"}}{control}' in joined
        assert "Analizando el proyecto" not in joined
        # The answer is untouched: the blocks travel beside it, never inside it.
        assert deltas[-1] == "Listo, deployed."

        # An old client that does not advertise the capability must never see the blocks.
        plain = await ask("Creame una landing page en React y desplegala", None)
        assert control not in "".join(sse_deltas(plain.text))
        assert "Listo, deployed." in "".join(sse_deltas(plain.text))
        await app.state.http.aclose()

    asyncio.run(run())


def test_a_plain_question_never_gets_a_checklist(monkeypatch, tmp_path):
    """A question that runs no tool must not open a list of steps that never happen."""
    password = tmp_path / "opencode-password"
    password.write_text("pw", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", tmp_path / "sessions")

    def backend(request: httpx.Request):
        if request.url.path in ("/sessions", "/search", "/observations"):
            return httpx.Response(200, json={} if request.url.path == "/sessions" else [])
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "oc-ses"})
        if request.url.path == "/event":
            return httpx.Response(200, text='data: {"type": "session.idle", "properties": {"sessionID": "oc-ses"}}\n\n',
                                  headers={"content-type": "text/event-stream"})
        if request.url.path.endswith("/todo"):
            return httpx.Response(200, json=[])
        if request.url.path.endswith("/message"):
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "42"}]})
        raise AssertionError(request.url)

    async def run():
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            response = await client.post("/v1/responses", headers={"Authorization": "Bearer " + "x" * 64},
                json={"model": "makima-super", "input": [{"role": "user", "content": "¿Cuanto es 6 por 7?"}],
                      "metadata": {"chat_id": "c2", "caps": "checklist"}, "stream": True})
            assert response.status_code == 200
            assert opencode_bridge.CONTROL not in "".join(sse_deltas(response.text))
        await app.state.http.aclose()

    asyncio.run(run())


def test_each_chat_gets_its_own_opencode_session(monkeypatch, tmp_path):
    """Two chats must never share an OpenCode session, whatever the transcripts look like."""
    password = tmp_path / "opencode-password"
    password.write_text("pw", encoding="utf-8")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    sessions_dir = tmp_path / "sessions"
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", sessions_dir)
    created = []

    def backend(request: httpx.Request):
        if request.url.path in ("/sessions", "/search", "/observations"):
            return httpx.Response(200, json={} if request.url.path == "/sessions" else [])
        if request.url.path == "/session/status":
            return httpx.Response(200, json={})
        if request.url.path == "/session":
            created.append(f"oc-{len(created) + 1}")
            return httpx.Response(200, json={"id": created[-1]})
        if request.url.path.endswith("/message"):
            return httpx.Response(200, json={"parts": [{"type": "text", "text": "ok"}]})
        raise AssertionError(request.url)

    messages = [{"role": "user", "content": "Hola"}]

    async def run():
        http = httpx.AsyncClient(transport=httpx.MockTransport(backend))
        # Chat A twice, then chat B with the very same transcript.
        await opencode_bridge.respond(http, messages, "", False, "chat-a")
        await opencode_bridge.respond(http, [*messages, {"role": "assistant", "content": "ok"},
                                             {"role": "user", "content": "y de nuevo"}], "", False, "chat-a")
        await opencode_bridge.respond(http, messages, "", False, "chat-b")
        # Three turns, two sessions: chat A reused its own, chat B had to create a new one.
        assert len(created) == 2, created
        # Chat A kept its own session for the follow-up; chat B never inherited it.
        assert sessions_dir.joinpath("chat-a.json").exists()
        assert sessions_dir.joinpath("chat-b.json").exists()
        assert (opencode_bridge.json.loads(sessions_dir.joinpath("chat-a.json").read_text())["session_id"]
                != opencode_bridge.json.loads(sessions_dir.joinpath("chat-b.json").read_text())["session_id"])
        await http.aclose()

    asyncio.run(run())


def test_audio_is_converted_locally_and_transient(monkeypatch):
    seen = []
    paths = []

    class FFmpeg:
        returncode = 0

        async def communicate(self, data):
            paths[-1].write_bytes(data)
            return b"", b""

    async def fake_ffmpeg(*args, **kwargs):
        assert "-ar" in args and "16000" in args
        paths.append(gateway.Path(args[-1]))
        return FFmpeg()

    monkeypatch.setattr(gateway.asyncio, "create_subprocess_exec", fake_ffmpeg)

    def whisper(request: httpx.Request):
        assert request.url.path == "/inference"
        seen.append(request.content)
        assert b"recording.wav" in request.content
        assert b"RIFF" in request.content
        return httpx.Response(200, json={"text": "Makima, esta es una prueba de voz."})

    with io.BytesIO() as audio:
        with wave.open(audio, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\x00\x00" * 16000)
        payload = audio.getvalue()

    async def run():
        app.state.token = "x" * 64
        app.state.http = httpx.AsyncClient(transport=httpx.MockTransport(whisper))
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://local") as client:
            response = await client.post("/v1/audio/transcriptions", headers={"Authorization": "Bearer " + "x" * 64},
                files={"file": ("recording.wav", payload, "audio/wav")}, data={"language": "es", "model": "whisper-1"})
            assert response.status_code == 200, response.text
            assert response.json()["text"].startswith("Makima")
            assert seen
            assert all(not path.exists() for path in paths)
        await app.state.http.aclose()

    asyncio.run(run())


def test_think_filter_drops_reasoning_even_when_split_across_deltas():
    assert ThinkFilter().feed("<think>razonamiento secreto</think>respuesta") == "respuesta"
    # A tag split across two deltas must not leak, which is why feed() holds back a short tail.
    split = ThinkFilter()
    assert split.feed("<think>secre") == ""
    assert split.feed("to</thi") == ""
    assert split.feed("nk>respuesta") == "respuesta"
    # Text around the span still streams through immediately.
    around = ThinkFilter()
    assert around.feed("antes<think>x</think>despues") == "antesdespues"
    # Two spans in one stream.
    assert ThinkFilter().feed("<think>a</think>uno<think>b</think>dos") == "unodos"
    # An unterminated span must never be flushed as the answer.
    unterminated = ThinkFilter()
    assert unterminated.feed("<think>razonamiento truncad") == ""
    assert unterminated.flush() == ""
    # Ordinary text is never delayed: only a suffix that could still become an opening tag is held,
    # and it is released at the end if the stream closes without one.
    tail = ThinkFilter()
    assert tail.feed("hola<thi") == "hola"
    assert tail.flush() == "<thi"
    assert ThinkFilter().feed("respuesta completa") == "respuesta completa"
