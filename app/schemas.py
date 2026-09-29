from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ReviewInput(StrictModel):
    mode: Literal["mcp", "scripted"] = "mcp"
    workbench_record_id: str = Field(min_length=1, max_length=100)
    title: str = Field(min_length=1, max_length=120)
    design: str = Field(min_length=10, max_length=8000)
    check_ids: list[str] = Field(min_length=1, max_length=8)

    @field_validator("check_ids")
    @classmethod
    def unique_checks(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("检查项不能重复")
        return value


class AnswersInput(StrictModel):
    revision: int = Field(ge=0)
    answers: dict[str, str] = Field(min_length=1, max_length=3)

    @field_validator("answers")
    @classmethod
    def bounded_answers(cls, value):
        if any(not v.strip() or len(v) > 2000 for v in value.values()):
            raise ValueError("每个回答需要 1–2000 字符，可填写‘暂不确定’")
        return value


class Question(StrictModel):
    id: str = Field(min_length=1, max_length=60)
    check_id: str
    text: str = Field(min_length=1, max_length=400)


class Citation(StrictModel):
    source_id: str
    quote: str = Field(min_length=4, max_length=500)


class Finding(StrictModel):
    check_id: str
    verdict: Literal["supported", "risk", "unknown", "not_applicable"]
    explanation: str = Field(min_length=1, max_length=1600)
    recommendation: str = Field(min_length=1, max_length=1000)
    citations: list[Citation] = Field(min_length=1, max_length=4)


class ModelOutput(StrictModel):
    kind: Literal["questions", "report"]
    summary: str = Field(min_length=1, max_length=1200)
    questions: list[Question] = Field(max_length=3)
    findings: list[Finding] = Field(max_length=8)
