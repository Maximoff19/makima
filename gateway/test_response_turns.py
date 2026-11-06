import asyncio
import json
import time

import httpx
import pytest
from fastapi import HTTPException
from fastapi.responses import StreamingResponse

import app as gateway
from response_turns import ResponseTurns

TURN = "turn_" + "a" * 32
QUERY = {"model": "makima", "input": "Hello", "stream": True, "metadata": {"chat_id": "chat-1", "turn_id": TURN}}


def delta(text):
    return gateway.event("response.output_text.delta", {"sequence_number": 1, "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": text})


def done(text):
    return gateway.event("response.output_text.done", {"sequence_number": 2, "item_id": "msg_1", "output_index": 0, "content_index": 0, "text": text})


def test_disconnect_keeps_producer_and_replays_without_second_inference(tmp_path):
    async def run():
        turns = ResponseTurns(tmp_path / "turns.db", heartbeat=0.01)
        started, release = asyncio.Event(), asyncio.Event()
        calls = 0

        async def producer():
            nonlocal calls
            calls += 1

            async def frames():
                yield delta("Hi")
                started.set()
                await release.wait()
                yield delta(" there")
                yield done("Hi there")
            return StreamingResponse(frames())

        try:
            turns.start(TURN, QUERY, producer)
            subscriber = turns.subscribe(TURN)
            assert await anext(subscriber) == ": connected\n\n"
            await started.wait()
            assert "Hi" in await anext(subscriber)
            assert await anext(subscriber) == ": keep-alive\n\n"
            await subscriber.aclose()  # iOS disconnects; only the subscriber ends.
            assert not turns.tasks[TURN].done()
            turns.start(TURN, QUERY, producer)  # Lost POST acknowledgement / reconnect.
            release.set()
            await turns.tasks[TURN]
            replay = "".join([frame async for frame in turns.subscribe(TURN)])
            assert replay.count('"delta": "Hi"') == 1
            assert '"text": "Hi there"' in replay
            assert turns.snapshot(TURN)["status"] == "completed"
            assert turns.snapshot(TURN)["output_text"] == "Hi there"
            assert calls == 1
            with pytest.raises(HTTPException) as error:
                turns.start(TURN, {**QUERY, "input": "Different"}, producer)
            assert error.value.status_code == 409
        finally:
            await turns.close()
    asyncio.run(run())


def test_explicit_stop_closes_upstream_and_cancels_before_start(tmp_path):
    async def run():
        turns = ResponseTurns(tmp_path / "turns.db")
        started, closed = asyncio.Event(), asyncio.Event()

        async def producer():
            async def frames():
                try:
                    started.set()
                    await asyncio.Event().wait()
                    yield done("")
                finally:
                    closed.set()
            return StreamingResponse(frames())

        turns.start(TURN, QUERY, producer)
        await started.wait()
        await turns.cancel(TURN)
        assert closed.is_set()
        assert turns.snapshot(TURN)["status"] == "cancelled"
        assert not turns.tasks
        other = "turn_" + "b" * 32
        turns.start(other, QUERY, producer)
        await turns.cancel(other)  # Task has not run yet.
        assert turns.snapshot(other)["status"] == "cancelled"
        assert not turns.tasks
        await turns.close()
    asyncio.run(run())


def test_restart_preserves_completed_output_and_marks_interrupted_turns(tmp_path):
    async def run():
        path = tmp_path / "turns.db"
        turns = ResponseTurns(path)
        now = time.time()
        turns.db.execute("INSERT INTO turns (id,fingerprint,status,created_at,updated_at) VALUES (?,?,?,?,?)",
                         (TURN, "fingerprint", "in_progress", now, now))
        turns.db.commit()
        turns.append(TURN, delta("partial"))
        turns.db.close()  # Simulate process loss, not graceful shutdown.
        restored = ResponseTurns(path)
        assert restored.snapshot(TURN)["status"] == "interrupted"
        assert restored.snapshot(TURN)["output_text"] == "partial"
        replay = "".join([frame async for frame in restored.subscribe(TURN)])
        assert "server restarted" in replay
        await restored.close()
    asyncio.run(run())


def test_premature_eof_and_timeout_are_failures_not_success(tmp_path):
    async def run():
        turns = ResponseTurns(tmp_path / "turns.db", timeout=0.02)

        async def producer():
            async def frames():
                yield delta("Partial")
            return StreamingResponse(frames())

        turns.start(TURN, QUERY, producer)
        await turns.tasks[TURN]
        assert turns.snapshot(TURN)["status"] == "failed"

        async def slow():
            await asyncio.sleep(10)

        other = "turn_" + "b" * 32
        turns.start(other, QUERY, slow)
        await turns.tasks[other]
        assert turns.snapshot(other)["status"] == "failed"
        await turns.close()
    asyncio.run(run())


def test_response_routes_require_auth_and_reuse_completed_turn(monkeypatch, tmp_path):
    calls = []

    async def generate(query, request):
        calls.append(query.model)

        async def frames():
            yield delta("Ready")
            yield done("Ready")
        return StreamingResponse(frames())

    monkeypatch.setattr(gateway, "generate_response", generate)

    async def run():
        gateway.app.state.token = "x" * 64
        turns = ResponseTurns(tmp_path / "turns.db")
        gateway.app.state.turns = turns
        headers = {"Authorization": "Bearer " + "x" * 64}
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=gateway.app), base_url="http://local") as client:
                assert (await client.post("/v1/responses", json=QUERY)).status_code == 401
                assert (await client.get(f"/v1/responses/{TURN}")).status_code == 401
                assert (await client.delete(f"/v1/responses/{TURN}")).status_code == 401
                first = await client.post("/v1/responses", headers=headers, json=QUERY)
                second = await client.post("/v1/responses", headers=headers, json=QUERY)
                assert first.status_code == second.status_code == 200
                assert first.text == second.text
                snapshot = (await client.get(f"/v1/responses/{TURN}", headers=headers)).json()
                assert snapshot["status"] == "completed"
                assert snapshot["output_text"] == "Ready"
                assert len(calls) == 1
                acknowledged = await client.post("/v1/response-turns", headers=headers, json=QUERY)
                assert acknowledged.status_code == 202
                assert acknowledged.json()["status"] == "completed"
                assert (await client.post("/v1/responses", headers=headers, json={**QUERY, "input": "changed"})).status_code == 409
                assert (await client.delete(f"/v1/responses/{TURN}", headers=headers)).status_code == 204
                assert (await client.get("/v1/responses/invalid", headers=headers)).status_code == 400
        finally:
            await turns.close()
    asyncio.run(run())


def test_cancel_before_delayed_post_never_starts_inference(tmp_path):
    async def run():
        turns = ResponseTurns(tmp_path / "turns.db")

        async def forbidden():
            raise AssertionError("A cancelled request must not execute")

        await turns.cancel(TURN)
        turns.start(TURN, QUERY, forbidden)
        assert not turns.tasks
        assert turns.snapshot(TURN)["status"] == "cancelled"
        await turns.close()
    asyncio.run(run())
