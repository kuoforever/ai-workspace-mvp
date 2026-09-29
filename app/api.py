import os
from contextlib import asynccontextmanager
from typing import Annotated

from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from pydantic import Field

from .knowledge import ROOT, canonical
from .review_service import Busy, InvalidOutput, ReviewService
from .schemas import AnswersInput, ReviewInput, StrictModel
from .store import Conflict

Key = Annotated[
    str,
    Header(alias="Idempotency-Key", min_length=1, max_length=100, pattern=r"^[a-zA-Z0-9_.:-]+$"),
]


class Submission(StrictModel):
    revision: int = Field(ge=0)
    input_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    output: dict


def summary(r):
    return {k: r[k] for k in ("id", "status", "revision", "created_at", "updated_at")} | {
        "title": r["input"]["title"],
        "mode": r["input"]["mode"],
        "workbench_record_id": r["input"]["workbench_record_id"],
    }


def markdown(r):
    lines = [
        f"# {r['input']['title']}",
        "",
        f"模式：{r['input']['mode']} · 状态：{r['status']}",
        f"评审：{r['id']} · 版本：{r['revision']}",
        f"输入 SHA-256：{r['input_sha256']}",
        f"知识版本：{r['catalog_version']}",
        "",
        "代码/实验：not_run；引用语义支持：未人工评估。",
        "宿主模型调用次数与 token 用量：未知。",
        "",
        "## 设计快照",
        "",
        r["input"]["design"],
    ]
    if r["input"]["mode"] == "scripted":
        lines += ["", "**离线模拟数据，未经模型评审。**"]
    if r["report"]:
        lines += ["", "## 评审", "", r["report"]["summary"]]
        for f in r["report"]["findings"]:
            lines += [
                "",
                f"### {f['check_id']} · {f['verdict']}",
                "",
                f["explanation"],
                "",
                f["recommendation"],
            ]
            for c in f["citations"]:
                s = r["sources"][c["source_id"]]
                lines += [
                    "",
                    f"来源 {s['id']} · {s['path']} · SHA-256 {s['sha256']}",
                    "",
                    *["> " + line for line in c["quote"].splitlines()],
                ]
    if r["questions"]:
        lines += ["", "## 澄清记录"]
        for q in r["questions"]:
            lines += ["", q["text"], "", r["answers"].get(q["id"], "待回答")]
    return "\n".join(lines) + "\n"


def create_app(data_dir=None):
    load_dotenv(ROOT / ".env")

    @asynccontextmanager
    async def lifespan(app):
        directory = data_dir or ROOT / os.getenv("AI_WORKSPACE_DATA", "data")
        app.state.service = ReviewService(directory)
        yield

    app = FastAPI(title="AI Workspace — SWE Review", version="0.1.0", lifespan=lifespan)

    @app.middleware("http")
    async def local_only(request: Request, call_next):
        host = request.url.hostname
        if host not in ("127.0.0.1", "localhost", "::1", "testserver"):
            return JSONResponse({"detail": "仅支持本机访问"}, 403)
        if request.method not in ("GET", "HEAD", "OPTIONS"):
            origin = request.headers.get("origin")
            if origin and origin != str(request.base_url).rstrip("/"):
                return JSONResponse({"detail": "拒绝跨源写请求"}, 403)
            if request.headers.get("sec-fetch-site") == "cross-site":
                return JSONResponse({"detail": "拒绝跨站写请求"}, 403)
            # A small fixed cap also applies to chunked requests, before JSON parsing.
            body = bytearray()
            async for chunk in request.stream():
                body.extend(chunk)
                if len(body) > 65536:
                    return JSONResponse({"detail": "请求超过 64 KiB"}, 413)
            request._body = bytes(body)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] = "frame-ancestors 'none'"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(Conflict)
    async def conflict(_, exc):
        return JSONResponse({"detail": str(exc)}, 409)

    @app.exception_handler(Busy)
    async def busy(_, exc):
        return JSONResponse({"detail": str(exc)}, 409, headers={"Retry-After": "1"})

    @app.exception_handler(InvalidOutput)
    async def invalid(_, exc):
        return JSONResponse({"detail": str(exc)}, 422)

    @app.exception_handler(KeyError)
    async def missing(_, __):
        return JSONResponse({"detail": "评审不存在"}, 404)

    @app.get("/api/config")
    def config():
        return {
            "modes": ["mcp", "scripted"],
            "default_mode": "mcp",
            "max_checks": 8,
            "max_input_chars": 8000,
            "max_submissions": 3,
            "model_usage_available": False,
        }

    @app.get("/api/catalog")
    def catalog():
        return app.state.service.knowledge.public_catalog()

    @app.get("/api/reviews")
    def reviews():
        return [summary(r) for r in app.state.service.store.list()]

    @app.post("/api/reviews", status_code=201)
    def create(body: ReviewInput, key: Key):
        try:
            return app.state.service.create(body, key)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

    @app.get("/api/reviews/{rid}")
    def read(rid: str):
        return app.state.service.store.get(rid)

    @app.post("/api/reviews/{rid}/answers")
    def answer(rid: str, body: AnswersInput, key: Key):
        return app.state.service.answer(rid, body, key)

    @app.get("/api/reviews/{rid}/context")
    def context(rid: str):
        return app.state.service.context(rid)

    @app.post("/api/reviews/{rid}/model-output")
    def submit(rid: str, body: Submission, key: Key):
        return app.state.service.submit(rid, body.revision, body.input_sha256, body.output, key)

    @app.get("/api/reviews/{rid}/export")
    def export(rid: str, format: str = Query("markdown", pattern="^(json|markdown)$")):
        r = app.state.service.store.get(rid)
        if format == "json":
            return PlainTextResponse(
                canonical(r),
                media_type="application/json",
                headers={"Content-Disposition": f'attachment; filename="review-{r["id"]}.json"'},
            )
        return PlainTextResponse(
            markdown(r),
            media_type="text/markdown; charset=utf-8",
            headers={"Content-Disposition": f'attachment; filename="review-{r["id"]}.md"'},
        )

    @app.get("/", include_in_schema=False)
    def home():
        return FileResponse(ROOT / "static" / "index.html")

    @app.get("/assets/{name}", include_in_schema=False)
    def asset(name: str):
        if name not in ("ai-review-ui.js", "ai-review.css"):
            raise HTTPException(404)
        return FileResponse(ROOT / "static" / name)

    return app


app = create_app()
