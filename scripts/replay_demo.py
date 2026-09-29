"""Replay a saved report through MCP; no new model inference is performed."""

import argparse
import asyncio
import copy
import json
import sys
import uuid
from pathlib import Path

from mcp_call import ROOT, call


async def replay():
    saved = json.loads((ROOT / "evidence/mcp-review.json").read_text(encoding="utf-8"))
    key = "demo-" + uuid.uuid4().hex

    async def checked(tool, arguments):
        result = await call(tool, arguments)
        if result.get("isError"):
            raise RuntimeError(result["content"])
        return result["structuredContent"]

    created = await checked(
        "start_review",
        {
            "title": "演示回放：" + saved["input"]["title"],
            "design": saved["input"]["design"],
            "check_ids": saved["input"]["check_ids"],
            "workbench_record_id": "demo-replay",
            "request_key": key + "-create",
        },
    )
    context = await checked("get_review_context", {"review_id": created["id"]})
    report = copy.deepcopy(saved["report"])
    report["summary"] = "【已保存报告回放；本次未调用模型】" + report["summary"]
    receipt = await checked(
        "submit_review_output",
        {
            "review_id": created["id"],
            "revision": context["revision"],
            "input_sha256": context["input_sha256"],
            "output": report,
            "request_key": key + "-submit",
        },
    )
    if receipt["status"] != "completed":
        raise RuntimeError(f"Replay did not complete: {receipt}")
    return {
        "kind": "saved_report_replay",
        "model_calls_this_replay": 0,
        "source": "evidence/mcp-review.json",
        "receipt": receipt,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    result = asyncio.run(replay())
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    print(rendered)
    print("Open the Web review history and select the review starting with 演示回放.")
