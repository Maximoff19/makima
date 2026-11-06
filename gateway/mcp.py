"""Minimal MCP client.

The gateway acts as an MCP *client*: it connects to MCP servers, discovers their tools,
and exposes them to the model. The iOS app does not need to know about MCP at all, which
is the point of mediating here rather than teaching the client the protocol.

Transport is Streamable HTTP with JSON-RPC 2.0, which is what hosted servers (Notion,
Linear, the reference servers) speak. There is no stdio transport: a stdio server would
mean spawning a subprocess of the gateway, and the gateway is read_only and non-root.

Trust boundary: an MCP server is third-party code that we hand a tool call from a model
that reads untrusted input. Servers are opt-in, per-server, and every failure is contained
to that server - a broken or hostile server degrades the feature, it does not take the
request down with it.
"""

import json
import logging
import os
import re
import time
from dataclasses import dataclass, field

import httpx

logger = logging.getLogger("makima.mcp")

PROTOCOL_VERSION = "2025-06-18"
CLIENT_INFO = {"name": "makima-gateway", "version": "1.0"}

# Tool names are namespaced so two servers cannot collide and so the model is told which
# service a tool belongs to.
TOOL_PREFIX = "mcp__"

DEFAULT_TIMEOUT = 30


@dataclass
class MCPServer:
    name: str
    url: str
    token: str = ""
    timeout: int = DEFAULT_TIMEOUT
    _tools: list[dict] = field(default_factory=list)
    _ready: bool = False
    _last_init: float = 0.0

    def describe(self) -> str:
        return f"{self.name} -> {self.url}"


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9_]+", "_", text.lower()).strip("_") or "server"


def servers() -> list[MCPServer]:
    """Read the server list from the environment.

    MAKIMA_MCP_SERVERS is a comma-separated list of name=url, optionally with
    name=url:token. Nothing is configured by default, so this feature is inert until
    someone opts in by setting it.
    """
    raw = os.getenv("MAKIMA_MCP_SERVERS", "").strip()
    if not raw:
        return []
    found: list[MCPServer] = []
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        name, _, target = chunk.partition("=")
        # The token may itself contain ':' so only split on the first one after the url.
        url, _, token = target.partition(":")
        if not url.startswith(("http://", "https://")):
            logger.error("MCP server %s has a non-http url, skipping", name)
            continue
        found.append(MCPServer(name=_slug(name), url=url, token=token))
    return found


def _post(http: httpx.AsyncClient, server: MCPServer, payload: dict) -> dict:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": PROTOCOL_VERSION,
    }
    if server.token:
        headers["Authorization"] = f"Bearer {server.token}"
    response = http.post(
        server.url,
        json=payload,
        headers=headers,
        timeout=server.timeout,
    )
    response.raise_for_status()
    # Streamable HTTP may answer with SSE even for a single result; take the first
    # data frame, which is the JSON-RPC reply we asked for.
    ctype = response.headers.get("content-type", "")
    if "text/event-stream" in ctype:
        for line in response.text.splitlines():
            if line.startswith("data:"):
                return json.loads(line[5:].strip())
        raise ValueError("no data frame in SSE response")
    return response.json()


async def ensure_tools(http: httpx.AsyncClient, server: MCPServer, force: bool = False) -> list[dict]:
    """Initialize if needed and cache the tool list. Never raises."""
    if server._ready and not force and time.monotonic() - server._last_init < 900:
        return server._tools
    try:
        init = await _post(
            http,
            server,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": CLIENT_INFO,
                },
            },
        )
        if "error" in init:
            logger.error("MCP %s initialize failed: %s", server.name, init["error"])
            return server._tools
        # The spec requires the client to confirm before calling anything else.
        try:
            await _post(
                http,
                server,
                {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            )
        except (httpx.HTTPError, ValueError) as exc:
            logger.debug("MCP %s initialized notification failed: %s", server.name, exc)

        listed = await _post(http, server, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = listed.get("result", {}).get("tools", [])
        if not isinstance(tools, list):
            tools = []
        server._tools = [t for t in tools if isinstance(t, dict) and t.get("name")]
        server._ready = True
        server._last_init = time.monotonic()
        logger.info("MCP %s exposes %d tools", server.name, len(server._tools))
    except (httpx.HTTPError, ValueError, json.JSONDecodeError) as exc:
        # A dead server must not break the request; the feature just goes away.
        logger.error("MCP %s unavailable: %s: %s", server.name, type(exc).__name__, exc)
        server._ready = False
    return server._tools


def tool_name(server: str, tool: str) -> str:
    return f"{TOOL_PREFIX}{_slug(server)}__{_slug(tool)}"


def openai_tools() -> list[dict]:
    """All MCP tools in the shape the Ollama chat API expects."""
    out: list[dict] = []
    for server in servers():
        for tool in server._tools:
            schema = tool.get("inputSchema") or tool.get("input_schema") or {"type": "object", "properties": {}}
            out.append(
                {
                    "type": "function",
                    "function": {
                        "name": tool_name(server.name, tool.get("name", "")),
                        "description": (tool.get("description") or "")[:400],
                        "parameters": schema,
                    },
                }
            )
    return out


def find(full_name: str) -> tuple[MCPServer, str] | None:
    """Map a namespaced tool name back to its server and real tool name."""
    if not full_name.startswith(TOOL_PREFIX):
        return None
    rest = full_name[len(TOOL_PREFIX):]
    server_name, _, tool_name_raw = rest.partition("__")
    if not server_name or not tool_name_raw:
        return None
    for server in servers():
        if server.name == server_name:
            return server, tool_name_raw
    return None


async def call(http: httpx.AsyncClient, full_name: str, arguments: dict) -> str:
    """Invoke an MCP tool. Returns text; errors come back as text, not exceptions."""
    located = find(full_name)
    if located is None:
        return f"Unknown MCP tool: {full_name}"
    server, real_name = located
    try:
        result = await _post(
            http,
            server,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": real_name, "arguments": arguments or {}},
            },
        )
    except (httpx.HTTPError, ValueError, json.JSONDecodeError) as exc:
        return f"MCP {server.name} call failed: {type(exc).__name__}: {exc}"
    if "error" in result:
        return f"MCP {server.name} error: {result['error']}"
    parts = result.get("result", {}).get("content", [])
    chunks = [
        part.get("text", "")
        for part in parts
        if isinstance(part, dict) and part.get("type") == "text"
    ]
    text = "\n".join(chunks).strip()
    if not text:
        text = json.dumps(result.get("result", {}))[:2000]
    return text[:8000]
