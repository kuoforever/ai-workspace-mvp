"""Versioned, domain-neutral workbench inputs and task deliverables."""

from typing import Annotated, Literal

from pydantic import ConfigDict, Field, JsonValue, field_validator, model_validator

from .schemas import Citation, StrictModel

Identifier = Annotated[str, Field(min_length=1, max_length=100, pattern=r"^[a-zA-Z0-9_.:-]+$")]
Text = Annotated[str, Field(min_length=1, max_length=1000)]
Verdict = Literal["met", "unmet", "unknown", "conflict", "not_applicable"]
TaskKind = Literal["review", "summarize", "compare", "organize", "draft", "plan"]


class WorkbenchModel(StrictModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class ObjectType(WorkbenchModel):
    kind: Identifier
    label: Text
    fields: dict[str, Text] = Field(default_factory=dict, max_length=40)
    states: list[Text] = Field(default_factory=list, max_length=30)


class WorkbenchObject(WorkbenchModel):
    id: Identifier
    kind: Identifier
    title: Text
    content: str = Field(default="", max_length=16000)
    fields: dict[str, JsonValue] = Field(default_factory=dict, max_length=40)
    state: str = Field(default="", max_length=100)
    parent_id: Identifier | None = None
    links: list[Identifier] = Field(default_factory=list, max_length=40)
    source: str = Field(min_length=1, max_length=300)
    availability: Literal["available", "metadata_only"] = "available"


class RequirementRule(WorkbenchModel):
    kind: Literal["required_fields", "field_equals", "state_requires"]
    fields: list[Text] = Field(default_factory=list, max_length=20)
    field: str | None = Field(default=None, min_length=1, max_length=100)
    expected: JsonValue = None
    state: str | None = Field(default=None, min_length=1, max_length=100)

    @model_validator(mode="after")
    def complete_rule(self):
        if self.kind == "field_equals":
            if not self.field or self.fields or self.state is not None:
                raise ValueError("field_equals 需要 field 与 expected")
        elif not self.fields or self.field is not None:
            raise ValueError("必填规则需要 fields")
        if self.kind == "state_requires" and not self.state:
            raise ValueError("state_requires 需要 state")
        if self.kind == "required_fields" and self.state is not None:
            raise ValueError("required_fields 不接受 state")
        return self


class Requirement(WorkbenchModel):
    id: Identifier
    text: str = Field(min_length=4, max_length=2000)
    object_ids: list[Identifier] = Field(default_factory=list, max_length=200)
    priority: Literal["must", "should"] = "must"
    source: str = Field(min_length=1, max_length=300)
    acceptance: str = Field(min_length=4, max_length=2000)
    conflicts_with: list[Identifier] = Field(default_factory=list, max_length=30)
    rule: RequirementRule | None = None


class WorkbenchPackage(WorkbenchModel):
    format: Literal["ai-workbench"] = "ai-workbench"
    schema_version: Literal[1] = 1
    id: Identifier
    title: str = Field(min_length=1, max_length=120)
    revision: int = Field(ge=0)
    structure: list[ObjectType] = Field(min_length=1, max_length=30)
    objects: list[WorkbenchObject] = Field(min_length=1, max_length=200)
    requirements: list[Requirement] = Field(min_length=1, max_length=100)
    provenance: dict[str, str] = Field(default_factory=dict, max_length=20)

    @model_validator(mode="after")
    def linked_package(self):
        types = {s.kind: s for s in self.structure}
        objects = {o.id: o for o in self.objects}
        requirements = {r.id for r in self.requirements}
        if len(types) != len(self.structure) or len(objects) != len(self.objects):
            raise ValueError("结构类型与对象编号必须唯一")
        if len(requirements) != len(self.requirements):
            raise ValueError("要求编号必须唯一")
        for spec in self.structure:
            if any(not key or len(key) > 100 for key in spec.fields):
                raise ValueError("字段名称需要 1–100 字符")
        for obj in self.objects:
            if obj.kind not in types or set(obj.fields) - set(types[obj.kind].fields):
                raise ValueError(f"对象 {obj.id} 的类型或字段缺少结构定义")
            if types[obj.kind].states and obj.state and obj.state not in types[obj.kind].states:
                raise ValueError(f"对象 {obj.id} 的状态未在结构中定义")
            if set(obj.links) - objects.keys() or (obj.parent_id and obj.parent_id not in objects):
                raise ValueError(f"对象 {obj.id} 引用了不存在的对象")
            seen = {obj.id}
            parent = obj.parent_id
            while parent:
                if parent in seen:
                    raise ValueError("对象父子关系不能循环")
                seen.add(parent)
                parent = objects[parent].parent_id
        for requirement in self.requirements:
            validate_requirement(requirement, objects, types)
            if (
                set(requirement.conflicts_with) - requirements
                or requirement.id in requirement.conflicts_with
            ):
                raise ValueError("冲突引用必须指向其他已定义要求")
        if len(self.model_dump_json()) > 800000:
            raise ValueError("规范化工作台超过 800,000 字符，请缩小导入范围")
        return self


def validate_requirement(requirement, objects, types):
    if set(requirement.object_ids) - objects.keys():
        raise ValueError("要求引用了不存在的对象")
    if requirement.rule:
        targets = requirement.object_ids or list(objects)
        fields = requirement.rule.fields or [requirement.rule.field]
        for oid in targets:
            if set(fields) - set(types[objects[oid].kind].fields):
                raise ValueError(f"要求 {requirement.id} 的规则引用了未定义字段")


class WorkbenchImport(WorkbenchModel):
    filename: str = Field(min_length=1, max_length=240)
    content: str = Field(min_length=1, max_length=12 * 1024 * 1024)


class TaskInput(WorkbenchModel):
    mode: Literal["mcp", "scripted"] = "mcp"
    title: str = Field(min_length=1, max_length=120)
    workbench: WorkbenchPackage
    task_type: TaskKind
    goal: str = Field(min_length=4, max_length=4000)
    scope: list[Identifier] = Field(default_factory=list, max_length=200)
    deliverable: str = Field(min_length=4, max_length=2000)
    requirements: list[Requirement] = Field(default_factory=list, max_length=30)

    @model_validator(mode="after")
    def task_scope(self):
        objects = {o.id: o for o in self.workbench.objects}
        types = {s.kind: s for s in self.workbench.structure}
        if set(self.scope) - objects.keys() or len(set(self.scope)) != len(self.scope):
            raise ValueError("处理范围必须由不重复的工作台对象编号组成")
        ids = {r.id for r in self.requirements}
        if len(ids) != len(self.requirements) or "delivery" in ids:
            raise ValueError("任务要求编号必须唯一，delivery 为保留编号")
        for requirement in self.requirements:
            validate_requirement(requirement, objects, types)
            if (
                set(requirement.conflicts_with) - ids
                or requirement.id in requirement.conflicts_with
            ):
                raise ValueError("任务冲突引用必须指向其他任务要求")
        return self


class TaskQuestion(WorkbenchModel):
    id: Identifier
    text: str = Field(min_length=4, max_length=600)
    requirement_ids: list[str] = Field(default_factory=list, max_length=10)


class RequirementResult(WorkbenchModel):
    requirement_id: str = Field(min_length=1, max_length=120)
    verdict: Verdict
    explanation: str = Field(min_length=4, max_length=2000)
    recommendation: str = Field(default="", max_length=1000)
    citations: list[Citation] = Field(min_length=1, max_length=8)


class TaskArtifact(WorkbenchModel):
    id: Identifier
    title: Text
    kind: TaskKind
    content: str = Field(min_length=4, max_length=20000)
    citations: list[Citation] = Field(min_length=1, max_length=20)


class ProposedChange(WorkbenchModel):
    id: Identifier
    object_id: Identifier
    target: Literal["content", "state", "field"]
    field: str | None = Field(default=None, min_length=1, max_length=100)
    value: JsonValue
    reason: str = Field(min_length=4, max_length=1000)
    citations: list[Citation] = Field(min_length=1, max_length=8)


class TaskOutput(WorkbenchModel):
    kind: Literal["questions", "result"]
    summary: str = Field(min_length=4, max_length=2000)
    questions: list[TaskQuestion] = Field(default_factory=list, max_length=3)
    requirement_results: list[RequirementResult] = Field(default_factory=list, max_length=131)
    artifacts: list[TaskArtifact] = Field(default_factory=list, max_length=8)
    changes: list[ProposedChange] = Field(default_factory=list, max_length=50)


class ApplyChanges(WorkbenchModel):
    revision: int = Field(ge=1)
    workbench_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    change_ids: list[Identifier] = Field(min_length=1, max_length=50)

    @field_validator("change_ids")
    @classmethod
    def unique_changes(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("修改编号不能重复")
        return value
