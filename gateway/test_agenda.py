import asyncio
import json
from datetime import datetime, timezone

import httpx
import pytest
from fastapi import HTTPException
from pydantic import ValidationError

import agenda
import app as gateway
import opencode_bridge


@pytest.fixture(autouse=True)
def isolated_agenda(monkeypatch, tmp_path):
    monkeypatch.setattr(agenda, "DB_PATH", tmp_path / "agenda.sqlite3")


def fields(**changes):
    return {"kind": "task", "title": "Finish the report", **changes}


def create(**changes):
    return agenda.AgendaCommand(action="create", item=agenda.AgendaFields(**fields(**changes)))


def test_crud_persistence_and_optimistic_versions():
    agenda.apply([create()], "chat-1")
    item = agenda.snapshot()["items"][0]
    assert item["chat_id"] == "chat-1" and item["version"] == 1
    command = agenda.AgendaCommand(action="update", id=item["id"], version=1,
                                  item=agenda.AgendaFields(**fields(completed=True)))
    agenda.apply([command])
    assert agenda.snapshot()["items"][0]["completed"] is True
    with pytest.raises(HTTPException) as error:
        agenda.apply([command])
    assert error.value.status_code == 409
    agenda.apply([agenda.AgendaCommand(action="delete", id=item["id"], version=2)])
    assert agenda.snapshot()["items"] == []


@pytest.mark.parametrize("changes", [
    {"title": "  "}, {"completed": "false"}, {"timezone": "not/a-zone"},
    {"due_at": "2026-10-01T09:00:00"}, {"repeat": "daily"},
    {"kind": "event", "start_at": "2026-10-01T09:00:00Z", "end_at": "2026-10-01T08:00:00Z"},
    {"kind": "reminder"}, {"unexpected": "field"},
])
def test_rejects_invalid_fields(changes):
    with pytest.raises(ValidationError):
        create(**changes)
    assert agenda.snapshot()["items"] == []


def test_proposal_is_atomic_and_retry_is_idempotent():
    broken = agenda.AgendaCommand(action="delete", id="missing", version=1)
    with pytest.raises(HTTPException):
        agenda.apply([create(), broken])
    assert agenda.snapshot()["items"] == []
    text = json.dumps({"makima_agenda": [create().model_dump(mode="json")], "reply": "Saved."})
    messages = [{"role": "user", "content": "Create a report task"}]
    assert agenda.execute_reply(text, messages, "chat-1") == "Saved."
    assert agenda.execute_reply(text, messages, "chat-1") == "Saved."
    assert len(agenda.snapshot()["items"]) == 1
    assert agenda.execute_reply("Ordinary answer", messages, "chat-1") == "Ordinary answer"
    with pytest.raises(ValueError):
        agenda.execute_reply('{"makima_agenda": [', messages, "chat-1")


def test_recurring_checkins_preserve_wall_clock_across_dst_and_stop_on_completion():
    agenda.apply([create(reminder_at="2026-10-31T09:00:00-04:00", repeat="daily",
                         timezone="America/New_York", message="Need help finishing the report?")])
    state = agenda.snapshot(datetime(2026, 10, 31, 12, tzinfo=timezone.utc))
    assert [value["fire_at"] for value in state["reminders"][:3]] == [
        "2026-10-31T13:00:00Z", "2026-11-01T14:00:00Z", "2026-11-02T14:00:00Z"]
    item = state["items"][0]
    agenda.apply([agenda.AgendaCommand(action="update", id=item["id"], version=1,
                                     item=agenda.AgendaFields(**fields(completed=True)))])
    assert agenda.snapshot()["reminders"] == []


def test_notifications_are_bounded_and_old_schedules_jump_to_current_window():
    for index in range(3):
        agenda.apply([create(title=f"Task {index}", reminder_at="2000-01-01T09:00:00Z", repeat="daily")])
    now = datetime(2026, 10, 1, 12, tzinfo=timezone.utc)
    state = agenda.snapshot(now)
    future = [item for item in state["reminders"] if item["fire_at"] > agenda.stamp(now)]
    assert len(future) == 60
    assert state["coverage_until"] == future[-1]["fire_at"]
    assert len({item["id"] for item in state["reminders"]}) == len(state["reminders"])


def test_authenticated_api_validates_and_mutates():
    async def run():
        gateway.app.state.token = "x" * 64
        headers = {"Authorization": "Bearer " + "x" * 64}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=gateway.app), base_url="http://local") as client:
            assert (await client.get("/v1/agenda")).status_code == 401
            assert (await client.post("/v1/agenda/commands", json=create().model_dump(mode="json"))).status_code == 401
            assert (await client.post("/v1/agenda/commands", headers=headers, json={"action": "create"})).status_code == 422
            result = await client.post("/v1/agenda/commands", headers=headers, json=create().model_dump(mode="json"))
            assert result.status_code == 200
            assert result.json()["items"][0]["title"] == "Finish the report"
            assert (await client.get("/v1/agenda", headers=headers)).json()["items"] == result.json()["items"]
            retry_headers = {**headers, "Idempotency-Key": "same-manual-save"}
            for _ in range(2):
                assert (await client.post("/v1/agenda/commands", headers=retry_headers,
                                          json=create(title="Retry-safe task").model_dump(mode="json"))).status_code == 200
            assert len((await client.get("/v1/agenda", headers=headers)).json()["items"]) == 2
    asyncio.run(run())


@pytest.mark.parametrize("stream", [False, True])
def test_super_commits_before_answer_and_never_streams_raw_commands(monkeypatch, tmp_path, stream):
    password = tmp_path / "password"
    password.write_text("test-password")
    monkeypatch.setattr(opencode_bridge, "PASSWORD_FILE", password)
    monkeypatch.setattr(opencode_bridge, "SESSION_DIR", tmp_path / "sessions")
    proposal = {"makima_agenda": [create().model_dump(mode="json")], "reply": "The report task is saved."}

    def backend(request):
        if request.url.path == "/session":
            return httpx.Response(200, json={"id": "session-1"})
        if request.url.path == "/event":
            return httpx.Response(200, text="")
        if request.url.path.endswith("/message"):
            assert "Personal agenda protocol" in json.loads(request.content)["system"]
            return httpx.Response(200, json={"parts": [{"type": "text", "text": json.dumps(proposal)}]})
        raise AssertionError(request.url)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(backend)) as http:
            result = await opencode_bridge.respond(http, [{"role": "user", "content": "Create a report task"}],
                                                    agenda.context("America/Lima"), stream, "chat-1")
            if stream:
                chunks = [chunk async for chunk in result.body_iterator]
                answer = "".join(chunks)
                assert "The report task is saved." in answer and "makima_agenda" not in answer
            else:
                assert result["output"][0]["content"][0]["text"] == proposal["reply"]
            assert agenda.snapshot()["items"][0]["chat_id"] == "chat-1"
    asyncio.run(run())
