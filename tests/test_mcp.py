import asyncio
import os
import socket
import subprocess
import sys
import time

import httpx
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from app.knowledge import ROOT
from app.workbench_tasks import demo_task_output


def test_real_stdio_protocol_with_web_state(tmp_path):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "app.api:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
        ],
        cwd=ROOT,
        env=os.environ | {"AI_WORKSPACE_DATA": str(tmp_path)},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    try:
        with httpx.Client(timeout=2, trust_env=False) as client:
            for _ in range(100):
                try:
                    if client.get(base + "/api/config").status_code == 200:
                        break
                except httpx.TransportError:
                    time.sleep(0.1)
            else:
                raise AssertionError("Web service did not start")

            async def scenario():
                params = StdioServerParameters(
                    command=sys.executable,
                    args=["-m", "app.mcp_server"],
                    cwd=str(ROOT),
                    env={"AI_WORKSPACE_URL": base},
                )
                async with (
                    stdio_client(params) as (read, write),
                    ClientSession(read, write) as session,
                ):
                    await session.initialize()
                    names = {t.name for t in (await session.list_tools()).tools}
                    assert names == {
                        "list_pending_reviews",
                        "get_review_context",
                        "start_review",
                        "get_check_catalog",
                        "submit_review_output",
                        "get_workbench_contract",
                        "import_workbench_input",
                        "start_workbench_task",
                        "list_pending_tasks",
                        "get_task_context",
                        "read_task_source",
                        "submit_task_output",
                    }
                    created = await session.call_tool(
                        "start_review",
                        {
                            "title": "协议测试",
                            "design": "订单创建使用请求键去重；失败处理尚未设计。",
                            "check_ids": ["CON-01"],
                            "request_key": "protocol-create",
                        },
                    )
                    assert not created.isError
                    r = created.structuredContent
                    context = (
                        await session.call_tool("get_review_context", {"review_id": r["id"]})
                    ).structuredContent
                    citation = context["sources"]["CON-01"]["text"].splitlines()[0]
                    result = await session.call_tool(
                        "submit_review_output",
                        {
                            "review_id": r["id"],
                            "revision": context["revision"],
                            "input_sha256": context["input_sha256"],
                            "request_key": "protocol-submit",
                            "output": {
                                "kind": "report",
                                "summary": "协议测试数据，不是质量评估。",
                                "questions": [],
                                "findings": [
                                    {
                                        "check_id": "CON-01",
                                        "verdict": "unknown",
                                        "explanation": "测试只验证数据传递和校验。",
                                        "recommendation": "由模型执行实际评审。",
                                        "citations": [{"source_id": "CON-01", "quote": citation}],
                                    }
                                ],
                            },
                        },
                    )
                    assert not result.isError
                    assert result.structuredContent["status"] == "completed"
                    workbench = client.get(base + "/api/workbenches/example").json()
                    started = await session.call_tool(
                        "start_workbench_task",
                        {
                            "request_key": "generic-create",
                            "input": {
                                "title": "通用工作台协议测试",
                                "workbench": workbench,
                                "task_type": "review",
                                "goal": "识别筹备计划的缺失信息与要求冲突。",
                                "deliverable": "逐条覆盖所有要求，并生成带引用的核对报告。",
                            },
                        },
                    )
                    assert not started.isError
                    tid = started.structuredContent["id"]
                    task_context = (
                        await session.call_tool("get_task_context", {"task_id": tid})
                    ).structuredContent
                    assert "task:delivery" in task_context["requirements"]
                    assert task_context["checks"]["workbench:budget-plan"]["verdict"] == "conflict"
                    original = await session.call_tool(
                        "read_task_source", {"task_id": tid, "source_id": "object:speakers"}
                    )
                    assert not original.isError and "嘉宾" in original.structuredContent["text"]
                    task = client.get(base + f"/api/tasks/{tid}").json()
                    submitted = await session.call_tool(
                        "submit_task_output",
                        {
                            "task_id": tid,
                            "revision": task_context["revision"],
                            "input_sha256": task_context["input_sha256"],
                            "request_key": "generic-result",
                            "output": demo_task_output(task).model_dump(),
                        },
                    )
                    assert not submitted.isError
                    assert submitted.structuredContent["status"] == "completed"
                    assert client.get(base + f"/api/tasks/{tid}").json()["result"]["artifacts"]
                    return r["id"]

            rid = asyncio.run(scenario())
            assert client.get(base + "/api/reviews/" + rid).json()["status"] == "completed"
    finally:
        process.terminate()
        process.wait(timeout=10)
