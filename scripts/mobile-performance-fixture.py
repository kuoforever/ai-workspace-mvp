"""Seed fixed, synthetic reviews for simulator measurements; never calls a model."""

import hashlib
import json
import uuid
from pathlib import Path
from urllib.request import Request, urlopen


def seed(output: Path) -> None:
    design = ("订单使用唯一请求键，重复请求返回原订单。支付超时后先查询状态，再决定重试。\n" * 250)[:8000]
    assert len(design) == 8000
    run_id = uuid.uuid4().hex
    ids = []
    for number in range(20):
        body = {
            "title": f"Performance fixture {number:02d}",
            "design": design,
            "mode": "scripted",
            "check_ids": ["CON-01", "FAIL-01"],
            "workbench_record_id": "simulator-performance",
        }
        request = Request(
            "http://127.0.0.1:8765/api/reviews",
            data=json.dumps(body, ensure_ascii=False).encode(),
            headers={"Content-Type": "application/json", "Idempotency-Key": f"perf-{run_id}-{number}"},
        )
        with urlopen(request, timeout=20) as response:
            review = json.load(response)
        assert review["status"] == "completed", review["status"]
        ids.append(review["id"])
    with urlopen("http://127.0.0.1:8765/api/reviews", timeout=20) as response:
        total_reviews = len(json.load(response))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "execution": "scripted-no-model",
                "review_count": 20,
                "backend_review_count": total_reviews,
                "design_scalars": len(design),
                "design_sha256": hashlib.sha256(design.encode()).hexdigest(),
                "review_ids": ids,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    seed(parser.parse_args().out)
