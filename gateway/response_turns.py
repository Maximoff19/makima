"""Single-worker, durable response replay independent of any HTTP subscriber."""

import asyncio
import hashlib
import json
import logging
import re
import sqlite3
import time
from contextlib import aclosing
from pathlib import Path

from fastapi import HTTPException
from fastapi.responses import StreamingResponse

logger = logging.getLogger("makima.turns")
SAFE_ID = re.compile(r"turn_[a-f0-9]{32}\Z")
TERMINAL = {"completed", "failed", "cancelled", "interrupted"}


class ResponseTurns:
    def __init__(self, path: Path, ttl: float = 86400, heartbeat: float = 10,
                 timeout: float = 3600, max_active: int = 4):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS turns (
                id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, chat_id TEXT,
                status TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                error TEXT, bytes INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS frames (
                turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
                position INTEGER NOT NULL, body TEXT NOT NULL,
                PRIMARY KEY (turn_id, position)
            );
        """)
        self.ttl, self.heartbeat, self.timeout = ttl, heartbeat, timeout
        self.max_active = max_active
        self.tasks: dict[str, asyncio.Task] = {}
        self.signals: dict[str, asyncio.Event] = {}
        # An interrupted tool turn must never be replayed into another inference.
        for row in self.db.execute("SELECT id FROM turns WHERE status NOT IN ('completed','failed','cancelled','interrupted')").fetchall():
            self.fail(row["id"], "interrupted", "The server restarted before this response finished.")
        self.prune()

    @staticmethod
    def validate(turn_id: str):
        if not SAFE_ID.fullmatch(turn_id):
            raise HTTPException(400, "Invalid response turn ID")

    def prune(self):
        with self.db:
            self.db.execute("DELETE FROM turns WHERE status IN ('completed','failed','cancelled','interrupted') AND updated_at < ?",
                            (time.time() - self.ttl,))
            self.db.execute("""DELETE FROM turns WHERE id IN (
                SELECT id FROM turns WHERE status IN ('completed','failed','cancelled','interrupted')
                ORDER BY updated_at DESC LIMIT -1 OFFSET 256)""")
        for turn_id in list(self.signals):
            if turn_id not in self.tasks and self.db.execute("SELECT 1 FROM turns WHERE id=?", (turn_id,)).fetchone() is None:
                del self.signals[turn_id]

    def row(self, turn_id: str):
        self.validate(turn_id)
        row = self.db.execute("SELECT * FROM turns WHERE id=?", (turn_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Response no longer available")
        return row

    def append(self, turn_id: str, body: str):
        size = len(body.encode("utf-8"))
        if self.row(turn_id)["bytes"] + size > 2_000_000:
            raise ValueError("Response replay exceeded its size limit")
        with self.db:
            position = self.db.execute("SELECT COALESCE(MAX(position),0)+1 FROM frames WHERE turn_id=?", (turn_id,)).fetchone()[0]
            self.db.execute("INSERT INTO frames VALUES (?,?,?)", (turn_id, position, body))
            self.db.execute("UPDATE turns SET bytes=bytes+?, updated_at=? WHERE id=?", (size, time.time(), turn_id))
        if signal := self.signals.get(turn_id):
            signal.set()

    def finish(self, turn_id: str, status: str, error: str | None = None):
        with self.db:
            self.db.execute("UPDATE turns SET status=?,error=?,updated_at=? WHERE id=?", (status, error, time.time(), turn_id))
        if signal := self.signals.get(turn_id):
            signal.set()

    def fail(self, turn_id: str, status: str, message: str):
        payload = {"type": "error", "sequence_number": 0, "code": status,
                   "message": message, "param": None}
        # Error delivery must remain possible after the replay limit is reached.
        with self.db:
            position = self.db.execute("SELECT COALESCE(MAX(position),0)+1 FROM frames WHERE turn_id=?", (turn_id,)).fetchone()[0]
            self.db.execute("INSERT INTO frames VALUES (?,?,?)", (turn_id, position, f"event: error\ndata: {json.dumps(payload)}\n\n"))
        self.finish(turn_id, status, message)

    def start(self, turn_id: str, query: dict, producer):
        self.validate(turn_id)
        self.prune()
        fingerprint = hashlib.sha256(json.dumps(query, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        existing = self.db.execute("SELECT fingerprint FROM turns WHERE id=?", (turn_id,)).fetchone()
        if existing:
            if existing["fingerprint"] and existing["fingerprint"] != fingerprint:
                raise HTTPException(409, "Response ID already belongs to a different request")
            return
        if len(self.tasks) >= self.max_active:
            raise HTTPException(429, "Too many active responses")
        now = time.time()
        with self.db:
            self.db.execute("INSERT INTO turns (id,fingerprint,chat_id,status,created_at,updated_at) VALUES (?,?,?,?,?,?)",
                            (turn_id, fingerprint, (query.get("metadata") or {}).get("chat_id"), "in_progress", now, now))
        self.signals[turn_id] = asyncio.Event()
        self.tasks[turn_id] = asyncio.create_task(self.produce(turn_id, producer), name=turn_id)

    async def produce(self, turn_id: str, producer):
        try:
            async with asyncio.timeout(self.timeout):
                response = await producer()
                done = False
                if not isinstance(response, StreamingResponse):
                    raise ValueError("Expected a streaming response")
                async with aclosing(response.body_iterator) as frames:
                    async for frame in frames:
                        body = frame.decode() if isinstance(frame, bytes) else frame
                        if body.startswith(":"):
                            continue
                        self.append(turn_id, body)
                        for line in body.splitlines():
                            if not line.startswith("data: "):
                                continue
                            payload = json.loads(line[6:])
                            kind = payload.get("type")
                            if kind == "error":
                                self.finish(turn_id, "failed", payload.get("message", "Generation failed"))
                                return
                            if kind in {"response.output_text.done", "response.completed"}:
                                done = True
                if not done:
                    raise ValueError("The model stream ended without a completed response")
                self.finish(turn_id, "completed")
        except asyncio.CancelledError:
            self.fail(turn_id, "cancelled", "Response cancelled.")
            raise
        except Exception as exc:
            logger.exception("Response turn failed: %s", turn_id)
            message = exc.detail if isinstance(exc, HTTPException) else "The server could not finish this response. Please try again."
            self.fail(turn_id, "failed", str(message))
        finally:
            self.tasks.pop(turn_id, None)

    async def subscribe(self, turn_id: str):
        self.row(turn_id)
        position = 0
        # Sends bytes immediately even during memory retrieval / cold model loading.
        yield ": connected\n\n"
        while True:
            signal = self.signals.get(turn_id)
            if signal:
                signal.clear()
            frames = self.db.execute("SELECT position,body FROM frames WHERE turn_id=? AND position>? ORDER BY position",
                                     (turn_id, position)).fetchall()
            for frame in frames:
                position = frame["position"]
                yield frame["body"]
            if self.row(turn_id)["status"] in TERMINAL:
                if not frames:
                    return
                continue
            if signal:
                try:
                    await asyncio.wait_for(signal.wait(), timeout=self.heartbeat)
                    continue
                except TimeoutError:
                    pass
            else:
                await asyncio.sleep(self.heartbeat)
            yield ": keep-alive\n\n"

    def snapshot(self, turn_id: str):
        row = dict(self.row(turn_id))
        text = ""
        for frame in self.db.execute("SELECT body FROM frames WHERE turn_id=? ORDER BY position", (turn_id,)):
            for line in frame[0].splitlines():
                if line.startswith("data: "):
                    payload = json.loads(line[6:])
                    if payload.get("type") == "response.output_text.delta":
                        text += payload.get("delta", "")
                    elif payload.get("type") == "response.output_text.done":
                        text = payload.get("text", text)
        return {key: row[key] for key in ("id", "chat_id", "status", "created_at", "updated_at", "error")} | {"output_text": text}

    async def cancel(self, turn_id: str):
        self.validate(turn_id)
        if self.db.execute("SELECT 1 FROM turns WHERE id=?", (turn_id,)).fetchone() is None:
            # A cancelled POST may still arrive after DELETE. Keep an idempotency tombstone.
            now = time.time()
            with self.db:
                self.db.execute("INSERT INTO turns (id,fingerprint,status,created_at,updated_at) VALUES (?,?,?,?,?)",
                                (turn_id, "", "cancelled", now, now))
            self.fail(turn_id, "cancelled", "Response cancelled.")
            return
        if task := self.tasks.get(turn_id):
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            self.tasks.pop(turn_id, None)
            if self.row(turn_id)["status"] not in TERMINAL:
                self.fail(turn_id, "cancelled", "Response cancelled.")

    async def close(self):
        tasks = list(self.tasks.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for turn_id in list(self.tasks):
            if self.row(turn_id)["status"] not in TERMINAL:
                self.fail(turn_id, "interrupted", "The server stopped before this response finished.")
        self.tasks.clear()
        self.db.close()
