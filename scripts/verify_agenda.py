"""Run inside the gateway container. Verify real Super writes; remove only this run's items."""

from datetime import datetime, timedelta
from pathlib import Path
from uuid import uuid4
from zoneinfo import ZoneInfo

import httpx


def main():
    prefix = "agenda-smoke-" + uuid4().hex[:12]
    token = Path("/run/secrets/makima_token").read_text().strip()
    headers = {"Authorization": "Bearer " + token}
    start = (datetime.now(ZoneInfo("America/Lima")) + timedelta(days=1)).replace(
        hour=9, minute=0, second=0, microsecond=0)
    due = start.isoformat()
    end = (start + timedelta(hours=1)).isoformat()
    metadata = {"chat_id": prefix, "timezone": "America/Lima"}
    messages = []
    with httpx.Client(base_url="http://127.0.0.1:8000", headers=headers, timeout=420) as client:
        def state():
            result = client.get("/v1/agenda")
            result.raise_for_status()
            return result.json()

        def ask(text):
            messages.append({"role": "user", "content": text})
            result = client.post("/v1/responses", json={"model": "makima-super", "input": messages,
                                                       "metadata": metadata})
            result.raise_for_status()
            reply = result.json()["output"][0]["content"][0]["text"]
            assert "makima_agenda" not in reply, "Raw command envelope reached the user"
            messages.append({"role": "assistant", "content": reply})
            print("Super reply:", reply, flush=True)

        try:
            assert client.get("/v1/agenda", headers={"Authorization": "Bearer invalid"}).status_code == 401
            ask(f"Create a personal task titled '{prefix} task', due {due}. "
                f"Remind me daily starting {due} in America/Lima with the message 'Need help with the pending report?'. "
                "Also create a calendar event titled '" + prefix + f" event' from {due} to {end}. "
                "Save both to my in-app agenda, not an implementation checklist.")
            owned = [item for item in state()["items"] if item["title"].startswith(prefix)]
            assert len(owned) == 2, "Super did not persist both requested items"
            task = next(item for item in owned if item["kind"] == "task")
            assert task["repeat"] == "daily" and task["timezone"] == "America/Lima"
            assert any(reminder["item_id"] == task["id"] for reminder in state()["reminders"])
            print("Verified: task, event and recurring reminders persisted.", flush=True)
            ask(f"Mark the personal task '{prefix} task' completed. Keep the event unchanged.")
            updated = next(item for item in state()["items"] if item["id"] == task["id"])
            assert updated["completed"] is True
            assert not any(reminder["item_id"] == task["id"] for reminder in state()["reminders"])
            print("Verified: chat completion stopped the task's check-ins.", flush=True)
        finally:
            for item in state()["items"]:
                if item["title"].startswith(prefix):
                    result = client.post("/v1/agenda/commands", json={"action": "delete", "id": item["id"],
                                                                     "version": item["version"]})
                    result.raise_for_status()
            assert not any(item["title"].startswith(prefix) for item in state()["items"])
            print("Removed this run's test items.", flush=True)


if __name__ == "__main__":
    main()
