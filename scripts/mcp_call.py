"""Small protocol client for reproducible MCP smoke tests; not a model or agent loop."""

import argparse
import asyncio
import json
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[1]


async def call(tool, arguments):
    params = StdioServerParameters(
        command=sys.executable, args=["-m", "app.mcp_server"], cwd=str(ROOT)
    )
    async with stdio_client(params) as (read, write), ClientSession(read, write) as session:
        await session.initialize()
        if tool == "list_tools":
            result = await session.list_tools()
        else:
            result = await session.call_tool(tool, arguments)
        return result.model_dump(mode="json", exclude_none=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("tool")
    parser.add_argument("--args", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    body = json.loads(args.args.read_text(encoding="utf-8")) if args.args else {}
    result = asyncio.run(call(args.tool, body))
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
        print(f"Saved MCP result to {args.out}")
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        print(text)
    if result.get("isError"):
        raise SystemExit(1)
