"""One dispatch point for every tool the model can call.

The previous loop had `if function.get("name") != "web_search": continue`, which silently
dropped any other tool: the model's tool call was fed back to it unanswered and the loop
either spun or stalled. Every tool now goes through dispatch() so a new source of tools
cannot be forgotten at the call site.
"""

import logging
import os

import httpx

import mcp
import terminal

logger = logging.getLogger("makima.tools")

# Ollama's chat API takes OpenAI-shaped function definitions.
SEARCH_TOOL = {
    "type": "function",
    "function": {
        "name": "web_search",
        "description": "Search the public web and return result titles, URLs and snippets.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
    },
}

TERMINAL_TOOL = {
    "type": "function",
    "function": {
        "name": "terminal",
        "description": (
            "Run a read-only diagnostic command inside an isolated sandbox and return its "
            "output. Only inspection commands are permitted; this cannot modify anything. "
            "Use it to check resources, processes and logs, never to install or change things."
        ),
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string", "description": "A single read-only command, e.g. 'uptime' or 'df -h'."}},
            "required": ["command"],
        },
    },
}

# Words that suggest the user wants a tool. Deliberately conservative: a false positive
# costs a wasted round trip, a false negative costs a wrong answer.
TERMINAL_HINTS = ("terminal", "vps", "servidor", "server", "shell", "consola", "logs", "procesos")
MCP_HINTS = ("notion", "linear", "mcp", "obsidian", "trello", "asana", "github issue")


def _mentions(text: str, needles: tuple[str, ...]) -> bool:
    low = text.lower()
    return any(n in low for n in needles)


def terminal_enabled() -> bool:
    return terminal.enabled()


async def collect(http: httpx.AsyncClient, question: str) -> list[dict]:
    """Build the tool list for this request."""
    tools: list[dict] = []

    if _mentions(question, TERMINAL_HINTS) and terminal_enabled():
        tools.append(TERMINAL_TOOL)

    if _mentions(question, MCP_HINTS):
        for server in mcp.servers():
            await mcp.ensure_tools(http, server)
        extra = mcp.openai_tools()
        if extra:
            tools.extend(extra)
            logger.info("Exposing %d MCP tools", len(extra))

    return tools


async def dispatch(http: httpx.AsyncClient, name: str, arguments: dict, question: str) -> str:
    """Run one tool call and return the text to feed back to the model."""
    if name == "web_search":
        from app import web_search  # imported late: app imports this module

        query = str(arguments.get("query") or question)
        return await web_search(http, query)

    if name == "terminal":
        if not terminal.enabled():
            return "The terminal tool is disabled on this server."
        return await _render_terminal(await terminal.run(str(arguments.get("command") or "")))

    if name.startswith(mcp.TOOL_PREFIX):
        return await mcp.call(http, name, arguments)

    return f"Unknown tool: {name}"


async def _render_terminal(result: dict) -> str:
    if not result.get("ok") and "stdout" not in result:
        return f"Command not run: {result.get('error', 'unknown reason')}"
    parts = []
    if result.get("stdout"):
        parts.append(result["stdout"].strip())
    if result.get("stderr"):
        parts.append(f"[stderr] {result['stderr'].strip()}")
    if result.get("exit_code"):
        parts.append(f"[exit {result['exit_code']}]")
    return "\n".join(parts)[:4000] or "(no output)"
