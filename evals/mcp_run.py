"""Queue/submit recorded host outputs via real stdio MCP, without generating model answers."""

import argparse
import asyncio
import os
import time
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from app.knowledge import ROOT

from .benchmark import EVAL, read, verify_freeze, write


async def run(args):
    frozen = verify_freeze()
    if urlsplit(args.url).hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("Evaluation uses an explicitly selected local service")
    params = StdioServerParameters(
        command=os.sys.executable,
        args=["-m", "app.mcp_server"],
        cwd=str(ROOT),
        env={"AI_WORKSPACE_URL": args.url},
    )
    async with stdio_client(params) as (reader, writer), ClientSession(reader, writer) as session:
        await session.initialize()
        if args.command == "queue":
            if args.out.exists():
                raise ValueError("队列文件已存在；不要覆盖已运行的证据")
            tasks = []
            for case in read(EVAL / "cases.json"):
                if case["split"] != args.split:
                    continue
                created = await session.call_tool(
                    "start_review",
                    {
                        "title": f"Eval {case['id']} | {case['title']}",
                        "design": case["design"],
                        "check_ids": case["check_ids"],
                        "request_key": f"{args.run_id}:{case['id']}:create",
                        "workbench_record_id": f"eval:{args.run_id}",
                    },
                )
                if created.isError:
                    raise RuntimeError(created.content)
                rid = created.structuredContent["id"]
                context = await session.call_tool("get_review_context", {"review_id": rid})
                if context.isError:
                    raise RuntimeError(context.content)
                tasks.append({"case_id": case["id"], "context": context.structuredContent})
                # Save progress after every item; interrupted collection can be inspected safely.
                write(
                    args.out,
                    {
                        "run_id": args.run_id,
                        "url": args.url,
                        "split": args.split,
                        "freeze_sha256": frozen,
                        "tasks": tasks,
                    },
                )
            print("Queued", len(tasks), "MCP reviews; no model was called")
        else:
            queue, responses = read(args.queue), read(args.responses)
            if (
                queue["url"] != args.url
                or queue["freeze_sha256"] != frozen
                or responses["freeze_sha256"] != frozen
            ):
                raise ValueError("Queue/service/freeze mismatch")
            if responses["profile"] != "mcp" or responses["split"] != queue["split"]:
                raise ValueError("Response profile/split mismatch")
            index = {r["case_id"]: r for r in responses["responses"]}
            if len(index) != len(responses["responses"]) or set(index) != {
                t["case_id"] for t in queue["tasks"]
            }:
                raise ValueError("Response coverage differs from queue")
            receipts = []
            for task in queue["tasks"]:
                c = task["context"]
                started = time.perf_counter()
                result = await session.call_tool(
                    "submit_review_output",
                    {
                        "review_id": c["review_id"],
                        "revision": c["revision"],
                        "input_sha256": c["input_sha256"],
                        "output": index[task["case_id"]]["output"],
                        "request_key": f"{queue['run_id']}:{task['case_id']}:submit-v1",
                    },
                )
                receipts.append(
                    {
                        "case_id": task["case_id"],
                        "protocol_round_trip_ms": round((time.perf_counter() - started) * 1000, 2),
                        "result": result.model_dump(mode="json", exclude_none=True),
                    }
                )
                write(
                    args.out,
                    {
                        "run_id": queue["run_id"],
                        "freeze_sha256": frozen,
                        "run_type": responses["run_type"],
                        "receipts": receipts,
                    },
                )
            # Read actual saved results; protocol success alone is not evidence of report persistence.
            snapshots = []
            with httpx.Client(timeout=10, trust_env=False) as client:
                for task in queue["tasks"]:
                    response = client.get(args.url + "/api/reviews/" + task["context"]["review_id"])
                    response.raise_for_status()
                    saved = response.json()
                    snapshots.append(
                        {
                            "case_id": task["case_id"],
                            "id": saved["id"],
                            "status": saved["status"],
                            "revision": saved["revision"],
                            "report": saved["report"],
                            "submission_attempts": saved["submission_attempts"],
                            "execution": saved["execution"],
                            "usage": saved["usage"],
                        }
                    )
            write(args.out.with_name("saved-reports.json"), snapshots)
            completed = sum(r["status"] == "completed" for r in snapshots)
            print(
                f"Persisted reports: {completed}/{len(snapshots)}; model timing and usage unobserved"
            )


def main():
    p = argparse.ArgumentParser()
    subs = p.add_subparsers(dest="command", required=True)
    queue = subs.add_parser("queue")
    queue.add_argument("--run-id", required=True)
    queue.add_argument("--split", choices=("dev", "acceptance"), default="acceptance")
    submit = subs.add_parser("submit")
    submit.add_argument("--queue", type=Path, required=True)
    submit.add_argument("--responses", type=Path, required=True)
    for sub in (queue, submit):
        sub.add_argument("--url", required=True, help="Use an isolated local evaluation service")
        sub.add_argument("--out", type=Path, required=True)
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
