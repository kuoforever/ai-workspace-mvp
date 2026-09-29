import copy

import pytest
from fastapi.testclient import TestClient

from app.api import create_app
from app.review_service import ReviewService, demo_output
from app.schemas import AnswersInput, ReviewInput


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path)) as c:
        yield c


def data(mode="mcp", short=False):
    return {
        "workbench_record_id": "record-A",
        "title": "订单重试",
        "mode": mode,
        "design": "订单使用请求键去重，支付超时后重试。"
        if short
        else (
            "订单使用请求键去重，重复请求返回原订单。支付超时后调用结果查询接口。"
            "设计约束为同一用户和请求键只创建一次订单，数据库设置唯一约束。"
            "幂等记录与订单同一事务提交，计划验证并发和重试，测试尚未执行。"
            "相同键不同金额返回冲突，幂等记录保留七天，过期请求需要新键。"
        ),
        "check_ids": ["CON-01", "FAIL-01"],
    }


def create(client, mode="mcp", short=False, key="create-1"):
    response = client.post("/api/reviews", json=data(mode, short), headers={"Idempotency-Key": key})
    assert response.status_code == 201, response.text
    return response.json()


def report(r):
    draft = copy.deepcopy(r)
    draft["answers"] = {"force": "report"}
    return demo_output(draft).model_dump()


def submit(client, r, output, key="submit-1", **overrides):
    body = {
        "revision": r["revision"],
        "input_sha256": r["input_sha256"],
        "output": output,
    } | overrides
    return client.post(
        f"/api/reviews/{r['id']}/model-output", json=body, headers={"Idempotency-Key": key}
    )


def test_scripted_complete_persists_and_exports(client):
    r = create(client, "scripted")
    assert r["status"] == "completed"
    assert r["execution"] == "not_run"
    assert r["usage"]["model_calls"] is None
    assert r["accepted_outputs"] == 1
    assert client.get(f"/api/reviews/{r['id']}").json()["report"] == r["report"]
    export = client.get(f"/api/reviews/{r['id']}/export")
    assert "离线模拟数据" in export.text and "SHA-256" in export.text
    assert "attachment" in export.headers["content-disposition"]


def test_create_double_click_and_key_conflict(client):
    r = create(client, "scripted")
    assert create(client, "scripted")["id"] == r["id"]
    conflict = client.post(
        "/api/reviews", json=data("mcp"), headers={"Idempotency-Key": "create-1"}
    )
    assert conflict.status_code == 409
    assert len(client.get("/api/reviews").json()) == 1


def test_mcp_report_replay_and_record_binding(client):
    r = create(client)
    assert r["status"] == "waiting_model"
    wrong = submit(client, r, report(r), input_sha256="0" * 64)
    assert wrong.status_code == 409
    done = submit(client, r, report(r)).json()
    assert done["status"] == "completed"
    assert done["input"]["workbench_record_id"] == "record-A"
    assert submit(client, r, report(r)).json()["accepted_outputs"] == 1
    assert submit(client, r, report(r), key="different").status_code == 409


def test_one_question_round_and_answer_idempotency(client):
    r = create(client)
    questions = {
        "kind": "questions",
        "summary": "补充事实",
        "findings": [],
        "questions": [{"id": "q1", "check_id": "CON-01", "text": "保留多久？"}],
    }
    waiting = submit(client, r, questions).json()
    assert waiting["status"] == "waiting_input"
    path = f"/api/reviews/{r['id']}/answers"
    body = {"revision": waiting["revision"], "answers": {"q1": "保留七天"}}
    assert (
        client.post(
            path, json=body | {"revision": 0}, headers={"Idempotency-Key": "stale"}
        ).status_code
        == 409
    )
    assert (
        client.post(
            path, json=body | {"answers": {"wrong": "七天"}}, headers={"Idempotency-Key": "wrong"}
        ).status_code
        == 409
    )
    headers = {"Idempotency-Key": "answer-1"}
    resumed = client.post(path, json=body, headers=headers).json()
    assert resumed["status"] == "waiting_model"
    assert resumed["sources"]["answer:q1"]["text"] == "保留七天"
    assert client.post(path, json=body, headers=headers).json()["revision"] == resumed["revision"]
    assert client.get(f"/api/reviews/{r['id']}/context").json()["allow_questions"] is False
    assert submit(client, resumed, questions, key="second-question").status_code == 422
    updated = client.get(f"/api/reviews/{r['id']}").json()
    done = submit(client, updated, report(updated), key="final").json()
    assert done["status"] == "completed" and done["accepted_outputs"] == 2


@pytest.mark.parametrize(
    "fault", ["forged_quote", "unknown_source", "missing_check", "false_support", "tampered_hash"]
)
def test_invalid_citations_and_coverage(client, fault):
    r = create(client)
    output = report(r)
    if fault == "forged_quote":
        output["findings"][0]["citations"][0]["quote"] = "This quotation does not exist."
    elif fault == "unknown_source":
        output["findings"][0]["citations"][0]["source_id"] = "invented"
    elif fault == "missing_check":
        output["findings"].pop()
    elif fault == "false_support":
        output["findings"][0]["verdict"] = "supported"
    else:
        r["sources"]["CON-01"]["sha256"] = "0" * 64
        client.app.state.service.store.save(r)
    assert submit(client, r, output).status_code == 422
    saved = client.get(f"/api/reviews/{r['id']}").json()
    assert saved["report"] is None and saved["accepted_outputs"] == 0


def test_budget_counts_rejections_and_duplicate_does_not(client):
    r = create(client)
    invalid = {"kind": "bogus"}
    assert submit(client, r, invalid).status_code == 422
    # Replay returns saved state, including error; it never resumes the graph a second time.
    replay = submit(client, r, invalid).json()
    assert replay["submission_attempts"] == 1 and replay["error"]
    for i in (2, 3):
        r = client.get(f"/api/reviews/{r['id']}").json()
        assert submit(client, r, invalid, key=f"bad-{i}").status_code == 422
    failed = client.get(f"/api/reviews/{r['id']}").json()
    assert failed["status"] == "failed"
    assert submit(client, failed, report(failed), key="fourth").status_code == 409


def test_restart_resumes_questions_and_never_reruns_running(tmp_path):
    service = ReviewService(tmp_path)
    r = service.create(ReviewInput(**data("scripted", True)), "start")
    assert r["status"] == "waiting_input"
    restart = ReviewService(tmp_path)
    done = restart.answer(
        r["id"], AnswersInput(revision=r["revision"], answers={"q1": "暂不确定"}), "answer"
    )
    assert done["status"] == "completed"
    assert done["accepted_outputs"] == 2
    pending = restart.create(ReviewInput(**data()), "pending")
    assert ReviewService(tmp_path).store.get(pending["id"])["status"] == "waiting_model"
    pending["status"] = "running"
    restart.store.save(pending)
    assert ReviewService(tmp_path).store.get(pending["id"])["status"] == "interrupted"


def test_busy_preserves_input(client):
    lock = client.app.state.service.lock
    with lock:
        response = client.post("/api/reviews", json=data(), headers={"Idempotency-Key": "busy"})
        assert response.status_code == 409 and response.headers["retry-after"] == "1"
    assert not client.get("/api/reviews").json()


def test_origin_host_body_limits_and_private_files(client):
    headers = {"Idempotency-Key": "bad", "Origin": "https://foreign.example"}
    assert client.post("/api/reviews", json=data(), headers=headers).status_code == 403
    assert client.get("/api/reviews", headers={"Host": "foreign.example"}).status_code == 403
    assert client.get("/assets/reviews.sqlite3").status_code == 404
    assert client.get("/.env").status_code == 404
    assert client.post("/api/reviews", content=b"x" * 65537).status_code == 413
    assert (
        client.post(
            "/api/reviews",
            json=data() | {"design": "x" * 8001},
            headers={"Idempotency-Key": "long"},
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/reviews",
            json=data() | {"check_ids": ["unknown"]},
            headers={"Idempotency-Key": "unknown"},
        ).status_code
        == 422
    )


def test_original_workbench_still_available_and_manual_results_are_separate(client):
    html = client.get("/").text
    assert 'id="bundle-data"' in html and "window.Handbook=" in html
    assert 'id="ai-review-launch"' in html
    assert "querySelectorAll('[data-ai-addon]')" in html
    r = create(client, "scripted")
    assert "checks" not in r["input"] and all(
        f["verdict"] == "unknown" for f in r["report"]["findings"]
    )
