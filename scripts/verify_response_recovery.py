"""Exercise deployed response ownership and SSE replay without logging credentials."""

import argparse
import json
import os
import shlex
import subprocess
import time
from uuid import uuid4

import httpx


def verify(client: httpx.Client, model: str, deadline_seconds: int, resume_turn: str | None = None):
    turn_id = resume_turn or "turn_" + uuid4().hex
    chat_id = client.get(f"/v1/responses/{turn_id}").json()["chat_id"] if resume_turn else "recovery-smoke-" + uuid4().hex
    payload = {"model": model, "input": "Responde solo con la palabra LISTO.", "stream": True,
               "max_output_tokens": 16, "metadata": {"turn_id": turn_id, "chat_id": chat_id}}
    path = f"/v1/responses/{turn_id}"
    started = time.monotonic()
    response = client.post("/v1/response-turns", json=payload)
    response.raise_for_status()
    assert response.status_code == 202
    print(f"{model}: acknowledged in {time.monotonic() - started:.2f}s", flush=True)
    try:
        # A real network connection, deliberately closed before inference finishes.
        with client.stream("POST", "/v1/responses", json=payload) as stream:
            stream.raise_for_status()
            assert next(stream.iter_lines()) == ": connected"
        deadline = time.monotonic() + deadline_seconds
        while True:
            status = client.get(path)
            status.raise_for_status()
            snapshot = status.json()
            if snapshot["status"] != "in_progress":
                break
            assert time.monotonic() < deadline, "Generation did not finish before smoke-test deadline"
            time.sleep(3)
        assert snapshot["status"] == "completed", snapshot.get("error")
        assert snapshot["output_text"].strip()
        replay_started = time.monotonic()
        replay = client.post("/v1/responses", json=payload)
        replay.raise_for_status()
        events = [json.loads(line[6:]) for line in replay.text.splitlines() if line.startswith("data: ")]
        final = next(event for event in events if event["type"] == "response.output_text.done")
        assert final["text"] == snapshot["output_text"]
        repeated = client.get(path).json()
        assert repeated["created_at"] == snapshot["created_at"]
        assert repeated["updated_at"] == snapshot["updated_at"], "Replay must not restart inference"
        print(f"{model}: completed with no subscriber in {time.monotonic() - started:.2f}s; "
              f"identical replay in {time.monotonic() - replay_started:.2f}s", flush=True)
    finally:
        client.delete(path).raise_for_status()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--ssh", required=True, help="SSH host containing the gateway")
    parser.add_argument("--deadline", type=int, default=600)
    parser.add_argument("--models", nargs="+", default=["makima-fast", "makima"])
    parser.add_argument("--resume-turn", help="Recover a smoke-test turn after the test client was interrupted")
    args = parser.parse_args()
    token = os.environ.get("MAKIMA_GATEWAY_TOKEN")
    if not token:
        # Capture stdout privately; never include token in process arguments or tool output.
        code = "from pathlib import Path; print(Path('/run/secrets/makima_token').read_text().strip())"
        token = subprocess.check_output([
            "ssh", "-o", "BatchMode=yes", args.ssh,
            "docker exec makima-gateway-1 python -c " + shlex.quote(code)
        ], text=True).strip()
    with httpx.Client(base_url=args.base_url, headers={"Authorization": f"Bearer {token}"}, timeout=30) as client:
        client.get("/health").raise_for_status()
        for model in args.models:
            verify(client, model, args.deadline, args.resume_turn)
        # DELETE before POST must also prevent late requests from starting work.
        cancelled = "turn_" + uuid4().hex
        path = f"/v1/responses/{cancelled}"
        assert client.delete(path).status_code == 204
        payload = {"model": args.models[0], "input": "This turn must not execute", "stream": True,
                   "metadata": {"turn_id": cancelled}}
        response = client.post("/v1/response-turns", json=payload)
        response.raise_for_status()
        assert response.json()["status"] == "cancelled"
        assert client.get(path).json()["status"] == "cancelled"
        print("Cancellation-before-POST: passed", flush=True)
        with httpx.Client(base_url=args.base_url, timeout=15) as anonymous:
            assert anonymous.get(path).status_code == 401
            assert anonymous.delete(path).status_code == 401
            assert anonymous.post("/v1/response-turns", json=payload).status_code == 401
        print("Authentication checks: passed", flush=True)


if __name__ == "__main__":
    main()
