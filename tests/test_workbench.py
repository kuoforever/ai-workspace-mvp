import json

import pytest
from fastapi.testclient import TestClient

from app.api import create_app
from app.knowledge import ROOT, digest
from app.schemas import AnswersInput
from app.workbench_import import DataScripts
from app.workbench_tasks import TaskService, demo_task_output


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path)) as c:
        yield c


def package():
    return json.loads((ROOT / "fixtures/event-workbench.json").read_text(encoding="utf-8"))


def task_input():
    return {
        "title": "筹备工作台核对",
        "mode": "mcp",
        "workbench": package(),
        "task_type": "organize",
        "goal": "按当前工作台资料识别阻塞、缺失证据和要求冲突。",
        "deliverable": "逐条列出要求满足情况，并生成相应任务产物。",
        "scope": [],
        "requirements": [],
    }


def create(client, **overrides):
    response = client.post(
        "/api/tasks", json=task_input() | overrides, headers={"Idempotency-Key": "create"}
    )
    assert response.status_code == 201, response.text
    return response.json()


def submit(client, task, output=None, key="output", **overrides):
    body = {
        "revision": task["revision"],
        "input_sha256": task["input_sha256"],
        "output": output or demo_task_output(task).model_dump(),
    } | overrides
    return client.post(
        f"/api/tasks/{task['id']}/model-output", json=body, headers={"Idempotency-Key": key}
    )


def test_contract_and_new_home_keep_engineering_template(client):
    contract = client.get("/api/workbenches/contract").json()
    assert set(contract["task_types"]) == {
        "review",
        "summarize",
        "compare",
        "organize",
        "draft",
        "plan",
    }
    assert "requirements" in contract["schema"]["required"]
    assert client.get("/?ai").text == client.get("/engineering").text


@pytest.mark.parametrize("kind", ["review", "summarize", "compare", "organize", "draft", "plan"])
def test_general_tasks_preserve_all_requirements_and_conflicts(client, kind):
    task = create(client, mode="scripted", task_type=kind)
    assert task["status"] == "completed"
    assert task["result"]["artifacts"][0]["kind"] == kind
    results = {r["requirement_id"]: r["verdict"] for r in task["result"]["requirement_results"]}
    assert results == {
        "workbench:owners": "unmet",
        "workbench:completed": "unmet",
        "workbench:budget-plan": "conflict",
        "workbench:budget-meeting": "conflict",
        "workbench:blockers": "unknown",
        "task:delivery": "unknown",
    }
    assert len(task["conflicts"]) == 1 and task["usage"]["model_calls"] is None
    exported = client.get(f"/api/tasks/{task['id']}/export").text
    assert "预算上限" in exported and "来源" in exported and "离线演示" in exported
    assert (
        client.get(f"/api/tasks/{task['id']}/export?format=workbench").json()
        == task["input"]["workbench"]
    )


@pytest.mark.parametrize("mode", ["mcp", "scripted"])
def test_maximum_goal_remains_complete_as_a_delivery_requirement(client, mode):
    goal = '目标包含完整要求与"原文"。\n' * 240
    goal = (goal + "继续核对。" * 800)[:4000]
    task = create(client, mode=mode, goal=goal, deliverable="完整交付。" * 400)
    assert task["input"]["goal"] == goal
    assert task["requirements"]["task:delivery"]["text"] == goal
    assert goal in task["sources"]["requirement:task:delivery"]["text"]
    if mode == "mcp":
        assert submit(client, task).json()["status"] == "completed"
    else:
        assert task["status"] == "completed"


def test_json_and_html_import_share_the_same_contract(client):
    content = json.dumps(package(), ensure_ascii=False)
    raw_json = client.post(
        "/api/workbenches/import", json={"filename": "活动.json", "content": content}
    )
    html = f'<html><script>alert("must not execute")</script><script type="application/json" id="workbench-data">{content}</script></html>'
    raw_html = client.post(
        "/api/workbenches/import", json={"filename": "活动.html", "content": html}
    )
    assert raw_json.status_code == raw_html.status_code == 200
    assert raw_json.json()["workbench"] == raw_html.json()["workbench"]
    assert raw_json.json()["import"]["requirement_count"] == 5


@pytest.mark.parametrize(
    "fault",
    [
        "missing_requirements",
        "dangling_link",
        "dangling_requirement",
        "unknown_type",
        "duplicate_object",
        "cyclic_parent",
        "unknown_rule_field",
        "invalid_state",
    ],
)
def test_admission_rejects_uninterpretable_workbenches(client, fault):
    value = package()
    if fault == "missing_requirements":
        value.pop("requirements")
    elif fault == "dangling_link":
        value["objects"][0]["links"] = ["missing"]
    elif fault == "dangling_requirement":
        value["requirements"][0]["object_ids"] = ["missing"]
    elif fault == "unknown_type":
        value["objects"][0]["kind"] = "unknown"
    elif fault == "duplicate_object":
        value["objects"][1]["id"] = value["objects"][0]["id"]
    elif fault == "cyclic_parent":
        value["objects"][0]["parent_id"] = "speakers"
        value["objects"][1]["parent_id"] = "venue"
    elif fault == "unknown_rule_field":
        value["requirements"][0]["rule"]["fields"] = ["undefined"]
    else:
        value["objects"][0]["state"] = "invented"
    response = client.post(
        "/api/workbenches/import", json={"filename": "invalid.json", "content": json.dumps(value)}
    )
    assert response.status_code == 422 and client.get("/api/tasks").json() == []


def test_incomplete_business_records_are_valid_inputs(client):
    response = client.post(
        "/api/workbenches/import",
        json={"filename": "incomplete.json", "content": json.dumps(package())},
    )
    assert response.status_code == 200
    assert response.json()["workbench"]["objects"][1]["fields"]["owner"] == ""


@pytest.mark.parametrize(
    "content",
    [
        '{"format":"ai-workbench","format":"other"}',
        '{"number":NaN}',
        '<script type="application/json" id="workbench-data">{}</script><script type="application/json" id="workbench-data">{}</script>',
        "<html><h1>没有结构化记录</h1></html>",
    ],
)
def test_ambiguous_or_unrecognized_imports_fail_explicitly(client, content):
    assert (
        client.post(
            "/api/workbenches/import", json={"filename": "input", "content": content}
        ).status_code
        == 422
    )


def test_original_html_and_current_record_import_keep_source_versions(client):
    result = client.get("/api/workbenches/engineering")
    assert result.status_code == 200, result.text
    workbench = result.json()["workbench"]
    assert len(workbench["requirements"]) == 12
    assert any(o["kind"] == "reference" for o in workbench["objects"])
    assert workbench["provenance"]["catalog_version"] == "2026.09.27-2"
    parser = DataScripts()
    parser.feed((ROOT / "static/index.html").read_text(encoding="utf-8"))
    record = json.loads(parser.scripts["record-data"])
    record["checks"]["CON-01"] = {"status": "待整改", "evidence": "当前操作未记录请求键"}
    imported = client.post(
        "/api/workbenches/import", json={"filename": "current.json", "content": json.dumps(record)}
    )
    assert imported.status_code == 200, imported.text
    check = next(o for o in imported.json()["workbench"]["objects"] if o["id"] == "CON-01")
    assert check["fields"]["evidence"] == "当前操作未记录请求键"
    record["catalogVersion"] = "unknown"
    assert (
        client.post(
            "/api/workbenches/import",
            json={"filename": "current.json", "content": json.dumps(record)},
        ).status_code
        == 422
    )


def test_scope_checks_and_additional_task_requirements(client):
    extra = {
        "id": "extra",
        "text": "场地必须有负责人。",
        "source": "本次用户要求",
        "acceptance": "场地 owner 字段有值。",
        "object_ids": ["venue"],
        "rule": {"kind": "required_fields", "fields": ["owner"]},
    }
    task = create(client, mode="scripted", scope=["venue"], requirements=[extra])
    assert task["checks"]["task:extra"]["verdict"] == "met"
    assert (
        task["checks"]["workbench:budget-plan"]["verdict"] == "not_applicable"
        and task["conflicts"] == []
    )


def change(oid="speakers", cid="repair"):
    return {
        "id": cid,
        "object_id": oid,
        "target": "field",
        "field": "owner",
        "value": "周",
        "reason": "补充筹备任务的明确负责人。",
        "citations": [{"source_id": "object:" + oid, "quote": "对象：" + oid}],
    }


@pytest.mark.parametrize(
    "fault",
    [
        "omitted_requirement",
        "forged_quote",
        "false_met",
        "hidden_conflict",
        "wrong_artifact",
        "out_of_scope_change",
        "duplicate_change",
        "metadata_evidence",
    ],
)
def test_result_validation_rejects_unsatisfied_contracts(client, fault):
    value = package()
    if fault == "metadata_evidence":
        value["objects"][1]["availability"] = "metadata_only"
    task = create(
        client, workbench=value, scope=["speakers"] if fault == "out_of_scope_change" else []
    )
    output = demo_task_output(task).model_dump()
    if fault == "omitted_requirement":
        output["requirement_results"].pop()
    elif fault == "forged_quote":
        output["artifacts"][0]["citations"][0]["quote"] = "完全不存在的原文"
    elif fault in ("false_met", "hidden_conflict", "metadata_evidence"):
        output["requirement_results"][2 if fault == "hidden_conflict" else 0]["verdict"] = "met"
    elif fault == "wrong_artifact":
        output["artifacts"][0]["kind"] = "plan"
    else:
        output["changes"] = [change("venue")]
        if fault == "duplicate_change":
            output["changes"].append(change("venue", "second"))
    assert submit(client, task, output).status_code == 422
    saved = client.get(f"/api/tasks/{task['id']}").json()
    assert saved["result"] is None and saved["accepted_outputs"] == 0


def test_changes_create_new_version_and_preserve_original(client):
    task = create(client)
    output = demo_task_output(task).model_dump()
    output["changes"] = [change()]
    response = submit(client, task, output)
    assert response.status_code == 200, response.text
    done = response.json()
    body = {
        "revision": done["revision"],
        "workbench_sha256": done["workbench_sha256"],
        "change_ids": ["repair"],
    }
    stale = client.post(
        f"/api/tasks/{task['id']}/apply",
        json=body | {"workbench_sha256": "0" * 64},
        headers={"Idempotency-Key": "stale"},
    )
    assert stale.status_code == 409
    applied = client.post(
        f"/api/tasks/{task['id']}/apply", json=body, headers={"Idempotency-Key": "apply"}
    )
    assert applied.status_code == 200, applied.text
    result = applied.json()
    assert result["input"]["workbench"]["objects"][1]["fields"]["owner"] == ""
    assert result["applied_workbench"]["objects"][1]["fields"]["owner"] == "周"
    assert result["applied_workbench"]["revision"] == task["input"]["workbench"]["revision"] + 1
    assert digest(result["input"]["workbench"]) == result["workbench_sha256"]
    assert (
        client.post(
            f"/api/tasks/{task['id']}/apply", json=body, headers={"Idempotency-Key": "apply"}
        ).json()
        == result
    )
    assert (
        client.get(f"/api/tasks/{task['id']}/export?format=workbench").json()
        == result["applied_workbench"]
    )


def test_changes_cannot_rewrite_conflicting_requirements(client):
    task = create(client)
    output = demo_task_output(task).model_dump()
    output["changes"] = [
        {
            "id": "budget",
            "object_id": "budget",
            "target": "field",
            "field": "limit",
            "value": 15000,
            "reason": "修改预算字段以展示冲突阻止应用。",
            "citations": [{"source_id": "object:budget", "quote": "对象：budget"}],
        }
    ]
    done = submit(client, task, output).json()
    result = client.post(
        f"/api/tasks/{task['id']}/apply",
        json={
            "revision": done["revision"],
            "workbench_sha256": done["workbench_sha256"],
            "change_ids": ["budget"],
        },
        headers={"Idempotency-Key": "apply"},
    )
    assert result.status_code == 409
    assert client.get(f"/api/tasks/{task['id']}").json()["applied_workbench"] is None


def test_task_retries_versions_and_restart_question_round(client, tmp_path):
    task = create(client)
    assert create(client)["id"] == task["id"]
    assert submit(client, task, input_sha256="0" * 64).status_code == 409
    questions = {
        "kind": "questions",
        "summary": "需要补充负责人信息。",
        "questions": [
            {
                "id": "q1",
                "text": "请确认嘉宾任务的负责人。",
                "requirement_ids": ["workbench:owners"],
            }
        ],
    }
    waiting = submit(client, task, questions).json()
    assert waiting["status"] == "waiting_input"
    service = TaskService(tmp_path / "tasks")
    answered = service.answer(
        task["id"],
        AnswersInput(revision=waiting["revision"], answers={"q1": "负责人为周，仍需确认交付物。"}),
        "answer",
    )
    assert answered["status"] == "waiting_model"
    assert answered["sources"]["answer:q1"]["text"] == "负责人为周，仍需确认交付物。"
    done = submit(client, answered, key="final")
    assert done.status_code == 200 and done.json()["status"] == "completed"
    assert submit(client, answered, key="final").json()["accepted_outputs"] == 2


def test_source_pagination_returns_original_text(client):
    value = package()
    value["objects"][3]["content"] = "记录内容。" * 1800
    task = create(client, workbench=value)
    context = client.get(f"/api/tasks/{task['id']}/context").json()
    assert context["sources"]["object:meeting"]["complete"] is False
    path = f"/api/tasks/{task['id']}/sources/object:meeting"
    first = client.get(path + "?limit=8000").json()
    second = client.get(path + f"?offset={first['next_offset']}&limit=8000").json()
    assert first["text"] + second["text"] == task["sources"]["object:meeting"]["text"]
    assert second["next_offset"] is None
    assert client.get(path + "?offset=999999").status_code == 422
    assert client.get(path + "?limit=8001").status_code == 422


def test_new_routes_keep_host_origin_and_size_limits(client):
    assert (
        client.post(
            "/api/tasks", json=task_input(), headers={"Origin": "https://foreign.example"}
        ).status_code
        == 403
    )
    assert client.get("/api/tasks", headers={"Host": "foreign.example"}).status_code == 403
    assert client.post("/api/tasks", content=b"x" * (4 * 1024 * 1024 + 1)).status_code == 413
    assert client.get("/assets/workbench_tasks.py").status_code == 404


def test_task_and_original_review_storage_are_separate(client):
    create(client, mode="scripted")
    assert client.get("/api/reviews").json() == [] and len(client.get("/api/tasks").json()) == 1


def test_task_budget_rejections_and_replays_are_durable(client):
    task = create(client)
    for i in range(3):
        previous = task
        assert submit(client, previous, {"kind": "invalid"}, key=f"bad-{i}").status_code == 422
        task = client.get(f"/api/tasks/{task['id']}").json()
        replay = submit(client, previous, {"kind": "invalid"}, key=f"bad-{i}")
        assert replay.status_code == 200 and replay.json()["submission_attempts"] == i + 1
    assert task["status"] == "failed"


def test_long_multiline_requirements_keep_literal_quotes_and_complete_results(client):
    value = package()
    value["requirements"][4]["text"] = '记录中的"事实"需要明确依据。\n' + "验收说明。" * 200
    task = create(client, mode="scripted", workbench=value)
    assert task["status"] == "completed"
    assert len(task["result"]["requirement_results"]) == 6
    assert (
        value["requirements"][4]["text"]
        in task["sources"]["requirement:workbench:blockers"]["text"]
    )


@pytest.mark.parametrize("missing", ["  \n", {}, []])
def test_whitespace_and_empty_containers_cannot_satisfy_required_fields(client, missing):
    value = package()
    value["objects"][0]["fields"]["owner"] = missing
    task = create(client, workbench=value, mode="scripted", scope=["venue"])
    assert task["checks"]["workbench:owners"]["verdict"] == "unmet"


def test_applying_a_change_cannot_violate_a_previously_met_must_rule(client):
    task = create(client, scope=["venue"])
    output = demo_task_output(task).model_dump()
    output["changes"] = [change("venue") | {"value": ""}]
    done = submit(client, task, output).json()
    response = client.post(
        f"/api/tasks/{task['id']}/apply",
        json={
            "revision": done["revision"],
            "workbench_sha256": done["workbench_sha256"],
            "change_ids": ["repair"],
        },
        headers={"Idempotency-Key": "apply"},
    )
    assert response.status_code == 409
    assert client.get(f"/api/tasks/{task['id']}").json()["applied_workbench"] is None
