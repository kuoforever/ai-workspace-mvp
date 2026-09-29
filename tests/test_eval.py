import copy
import json

import pytest

from app.knowledge import Knowledge
from evals import benchmark as bench


def envelope():
    return {
        "profile": "mcp",
        "split": "acceptance",
        "run_type": "same_session_pilot",
        "freeze_sha256": bench.verify_freeze(),
        "responses": [],
    }


def row():
    case = next(c for c in bench.read(bench.EVAL / "cases.json") if c["id"] == "accept-01")
    source = Knowledge().retrieve(case)["CON-01"]
    return {
        "case_id": case["id"],
        "output": {
            "kind": "report",
            "summary": "评测器测试数据。",
            "questions": [],
            "findings": [
                {
                    "check_id": "CON-01",
                    "verdict": "unknown",
                    "explanation": "只验证计数逻辑，不作为模型判断。",
                    "recommendation": "后续独立评估。",
                    "citations": [{"source_id": "CON-01", "quote": source["text"].splitlines()[0]}],
                }
            ],
        },
    }


def test_missing_cases_remain_in_denominator_and_quality_unknown():
    run = envelope()
    run["responses"] = [row()]
    result = bench.score(run)
    assert result["sample_count"] == 8 and result["valid_report_count"] == 1
    assert (
        result["reference_verdict_match_count"] == 0
    )  # Plausible structure is not reference correctness.
    assert result["independent_quality_comparison"] is False
    assert result["human_semantic_support_rate"] is None and result["model_calls"] is None


@pytest.mark.parametrize("fault", ["duplicate", "unknown_id", "stale_freeze"])
def test_evaluator_rejects_ambiguous_runs(fault):
    run = envelope()
    run["responses"] = [row()]
    if fault == "duplicate":
        run["responses"].append(copy.deepcopy(run["responses"][0]))
    elif fault == "unknown_id":
        run["responses"][0]["case_id"] = "invented"
    else:
        run["freeze_sha256"] = "0" * 64
    with pytest.raises(ValueError):
        bench.score(run)


def test_forged_quote_is_counted_and_rejected():
    run = envelope()
    run["responses"] = [row()]
    run["responses"][0]["output"]["findings"][0]["citations"][0]["quote"] = (
        "This is not in the source."
    )
    result = bench.score(run)
    assert result["citation_count"] == 1 and result["citation_exact_matches"] == 0
    assert result["valid_report_count"] == 0


def test_invalid_schema_does_not_hide_empty_or_forged_citations():
    run = envelope()
    run["responses"] = [row()]
    output = run["responses"][0]["output"]
    output["kind"] = "invalid"
    output["findings"][0]["citations"] = [
        {"source_id": "CON-01", "quote": ""},
        {"source_id": "invented", "quote": "not an existing citation"},
    ]
    result = bench.score(run)
    assert result["citation_count"] == 2 and result["citation_exact_matches"] == 0
    assert result["valid_report_count"] == 0


def test_prepared_model_input_does_not_include_reference_answers(tmp_path):
    direct = bench.prepare("direct", "acceptance", tmp_path / "direct.json")
    mcp = bench.prepare("mcp", "acceptance", tmp_path / "mcp.json")
    assert len(direct["tasks"]) == len(mcp["tasks"]) == 8
    for task in direct["tasks"]:
        assert "reference" not in task and "rubric" not in task
        assert set(task["sources"]) == {"input", *task["check_ids"]}
    assert len(mcp["tasks"][0]["sources"]) > len(direct["tasks"][0]["sources"])


def test_frozen_dataset_changes_are_detected(monkeypatch):
    original = bench.freeze_payload()
    changed = json.loads(json.dumps(original))
    changed["files"]["evals/cases.json"] = "tampered"
    monkeypatch.setattr(bench, "freeze_payload", lambda: changed)
    with pytest.raises(ValueError, match="冻结"):
        bench.verify_freeze()


def test_windows_manifest_is_valid_with_posix_checkout_paths(monkeypatch):
    manifest = bench.read(bench.EVAL / "manifest.json")
    assert any("\\" in key for key in manifest["files"])
    posix_payload = copy.deepcopy(manifest)
    posix_payload["files"] = {
        key.replace("\\", "/"): value for key, value in manifest["files"].items()
    }
    monkeypatch.setattr(bench, "freeze_payload", lambda: posix_payload)
    assert bench.verify_freeze() == bench.digest(manifest)
