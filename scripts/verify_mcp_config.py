"""Launch the registered Codex stdio command with the official MCP client."""

import argparse
import asyncio
import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def verify(config):
    transport = config["transport"]
    if not config["enabled"] or transport["type"] != "stdio":
        raise ValueError("Expected an enabled stdio MCP configuration")
    params = StdioServerParameters(
        command=transport["command"],
        args=transport["args"],
        env=transport.get("env"),
        cwd=transport.get("cwd"),
    )
    async with stdio_client(params) as (read, write), ClientSession(read, write) as session:
        initialized = await session.initialize()
        names = sorted(tool.name for tool in (await session.list_tools()).tools)
        catalog = await session.call_tool("get_check_catalog", {"query": "CON-01", "limit": 1})
        if catalog.isError or catalog.structuredContent["checks"][0]["id"] != "CON-01":
            raise RuntimeError("Registered server could not retrieve a check from the Web API")
        return {
            "verified_at": datetime.now(UTC).isoformat(),
            "configuration_name": config["name"],
            "enabled": config["enabled"],
            "transport": transport["type"],
            "server_name": initialized.serverInfo.name,
            "tools": names,
            "catalog_read": "CON-01",
            "passed": True,
            "scope": "Registered Codex command launched with official MCP client; current chat tool refresh is not asserted",
            "model_calls": 0,
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(
        subprocess.check_output(
            ["codex", "mcp", "get", "swe-workspace", "--json"], encoding="utf-8"
        )
    )
    result = asyncio.run(verify(config))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Registered command verified:", ", ".join(result["tools"]))
