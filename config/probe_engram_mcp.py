#!/usr/bin/env python3
"""Probe the Engram MCP stdio server the way OpenCode does.

Sends a real initialize handshake followed by tools/list, then prints the tool
names. Used to verify the shared-SQLite integration independently of the model.
"""
import json
import subprocess
import sys

def send(msg):
    return (json.dumps(msg) + "\n").encode()

init = {
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "probe", "version": "1"},
    },
}
initialized = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
list_tools = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}

payload = send(init) + send(initialized) + send(list_tools)

proc = subprocess.run(
    ["/opt/bin/engram", "mcp", "--tools=agent", "--project", "makima-personal"],
    input=payload,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=30,
    env={"ENGRAM_DATA_DIR": "/data/engram", "PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp"},
)

seen_init = False
tools = []
for line in proc.stdout.decode(errors="replace").splitlines():
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("id") == 1 and "result" in d:
        seen_init = True
        print("serverInfo:", json.dumps(d["result"].get("serverInfo", {})))
    if d.get("id") == 2 and "result" in d:
        tools = [t["name"] for t in d["result"].get("tools", [])]

print(f"initialize_ok={seen_init} tools={len(tools)}")
for t in tools:
    print("  -", t)
if not seen_init:
    print("stderr:", proc.stderr.decode(errors="replace")[:400], file=sys.stderr)
