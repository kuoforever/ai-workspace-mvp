"""Read workbench data without running imported HTML or JavaScript."""

import hashlib
import json
from html.parser import HTMLParser

from .knowledge import Knowledge, canonical
from .workbench_schema import WorkbenchPackage

MAX_IMPORT_BYTES = 12 * 1024 * 1024


def load_json(text):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"JSON 字段重复：{key}")
            value[key] = item
        return value

    def invalid_number(value):
        raise ValueError(f"不支持的 JSON 数值：{value}")

    try:
        return json.loads(text, object_pairs_hook=unique, parse_constant=invalid_number)
    except (RecursionError, json.JSONDecodeError) as exc:
        raise ValueError("文件不是有效的 JSON 数据") from exc


class DataScripts(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.active = None
        self.scripts = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "script" and attrs.get("id") in {"record-data", "bundle-data", "workbench-data"}:
            if attrs["id"] in self.scripts:
                raise ValueError("工作台包含重复的数据区块")
            if attrs.get("type") != "application/json":
                raise ValueError("工作台数据区块必须为 application/json")
            self.active = attrs["id"]
            self.scripts[self.active] = ""

    def handle_data(self, data):
        if self.active:
            self.scripts[self.active] += data

    def handle_endtag(self, tag):
        if tag == "script":
            self.active = None


def import_workbench(filename, content, knowledge=None):
    if len(content.encode("utf-8")) > MAX_IMPORT_BYTES:
        raise ValueError("文件超过 12 MiB，请缩小工作台或移除大附件")
    content = content.lstrip("\ufeff")
    bundle = None
    if content.lstrip().startswith("<"):
        parser = DataScripts()
        parser.feed(content)
        key = "workbench-data" if "workbench-data" in parser.scripts else "record-data"
        if key not in parser.scripts:
            raise ValueError("HTML 缺少工作台数据区块；请导出 ai-workbench JSON 或本项目工作台")
        record = load_json(parser.scripts[key])
        if "bundle-data" in parser.scripts:
            bundle = load_json(parser.scripts["bundle-data"])
    else:
        record = load_json(content)
    if not isinstance(record, dict):
        raise TypeError("工作台必须是 JSON 对象")
    warnings = []
    if record.get("format") == "swe-handbook-record":
        record, warnings = legacy_workbench(record, bundle, knowledge or Knowledge())
    elif record.get("format") != "ai-workbench":
        raise ValueError("不支持此格式；需要 ai-workbench 或 swe-handbook-record")
    package = WorkbenchPackage.model_validate(record)
    return {
        "workbench": package.model_dump(),
        "warnings": warnings,
        "import": {
            "filename": filename,
            "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            "object_count": len(package.objects),
            "requirement_count": len(package.requirements),
            "metadata_only": [o.id for o in package.objects if o.availability == "metadata_only"],
        },
    }


def legacy_workbench(record, bundle, knowledge):
    if record.get("schemaVersion") not in (1, 2):
        raise ValueError("工程工作台记录版本不受支持")
    for field in (
        "meta",
        "checks",
        "decisions",
        "drafts",
        "attachments",
        "accountability",
        "practice",
    ):
        if field in record and not isinstance(record[field], dict):
            raise ValueError(f"工程工作台 {field} 格式错误")
    if not isinstance(record.get("scope"), list):
        raise TypeError("工程工作台缺少检查范围")
    if bundle is not None:
        if not isinstance(bundle, dict) or bundle.get("version") != record.get("catalogVersion"):
            raise ValueError("工作台记录与内嵌知识版本不一致")
        catalog = bundle
    else:
        if record.get("catalogVersion") != knowledge.version:
            raise ValueError("此 JSON 的知识版本与本机不一致；请导入包含原知识的完整 HTML")
        catalog = knowledge.catalog
    checks = {c["id"]: c for c in catalog.get("checks", [])}
    scope = list(
        dict.fromkeys(
            record["scope"] + list(record.get("checks", {})) + list(record.get("drafts", {}))
        )
    )
    if not scope or set(scope) - checks.keys():
        raise ValueError("检查范围为空或缺少对应的检查定义")
    objects, requirements, warnings = [], [], []
    types = {}

    def add(
        oid,
        kind,
        title,
        fields=None,
        content="",
        state="",
        path="",
        links=None,
        availability="available",
    ):
        fields = fields or {}
        spec = types.setdefault(kind, {"kind": kind, "label": kind, "fields": {}, "states": []})
        spec["fields"].update({key: key for key in fields})
        objects.append(
            {
                "id": oid,
                "kind": kind,
                "title": title,
                "fields": fields,
                "content": content,
                "state": state,
                "source": path or f"record-data/{oid}",
                "links": links or [],
                "availability": availability,
            }
        )

    add("meta", "record", "工作背景", record.get("meta", {}), path="record-data/meta")
    # Carry the knowledge as data objects. Task contexts use bounded excerpts plus a source reader.
    document_ids = {}
    for index, doc in enumerate(catalog.get("docs", [])):
        oid = f"reference-{index}"
        document_ids[doc["id"]] = oid
        add(
            oid,
            "reference",
            doc["title"],
            {"topic": doc.get("topic", "")},
            content=doc.get("text", ""),
            path=doc.get("path", doc["id"]),
        )
    for cid in scope:
        check = checks[cid]
        links = [
            document_ids[d["id"]]
            for d in catalog.get("docs", [])
            if d.get("topic") == check.get("topic")
        ]
        stored = record.get("checks", {}).get(cid, {})
        if not isinstance(stored, dict):
            raise TypeError("检查记录必须为对象")
        add(
            cid,
            "check",
            check["question"],
            stored,
            state=stored.get("status", "未检查"),
            links=links,
        )
        requirements.append(
            {
                "id": cid,
                "text": check["question"],
                "object_ids": [cid],
                "acceptance": check["evidence"],
                "source": f"检查定义/{cid}",
            }
        )
        if cid in record.get("drafts", {}):
            add(
                f"draft-{cid}",
                "draft",
                f"{cid} 待确认填写",
                record["drafts"][cid],
                state="草稿",
                links=[cid],
            )
    for did, value in record.get("decisions", {}).items():
        add(did, "decision", did, value, state=value.get("status", "提议"))
    for pid, value in record.get("practice", {}).items():
        add(f"practice-{pid}", "practice", pid, value)
    for key in ("accountability", "review", "flow"):
        if record.get(key):
            add(key, "record", key, record[key])
    for aid, value in record.get("attachments", {}).items():
        if not isinstance(value, dict):
            raise TypeError("附件记录必须为对象")
        metadata = {k: v for k, v in value.items() if k != "data"}
        text = ""
        available = "metadata_only"
        if value.get("type") in ("text/plain", "text/markdown") and value.get("data"):
            import base64

            try:
                raw = base64.b64decode(value["data"], validate=True)
                if hashlib.sha256(raw).hexdigest() != value.get("sha256") or len(raw) != value.get(
                    "size"
                ):
                    raise ValueError("附件摘要或大小不匹配")
                text = raw.decode("utf-8-sig")
                available = "available"
            except (ValueError, UnicodeError) as exc:
                raise ValueError(f"附件 {aid} 的 UTF-8 文本无法核对") from exc
        if available == "metadata_only":
            warnings.append(f"附件 {metadata.get('name', aid)} 仅导入元信息，未读取原文件内容。")
        add(
            aid,
            "attachment",
            metadata.get("name", aid),
            metadata,
            content=text,
            availability=available,
        )
    # Evidence links are explicit; missing referenced attachments cannot be silently dropped.
    for obj in objects:
        obj["links"] += obj["fields"].get("evidenceFiles", [])
    package = {
        "format": "ai-workbench",
        "schema_version": 1,
        "id": record.get("id"),
        "title": record.get("meta", {}).get("title") or "导入的工程工作台",
        "revision": record.get("revision", 0),
        "structure": list(types.values()),
        "objects": objects,
        "requirements": requirements,
        "provenance": {
            "adapter": "swe-handbook-record",
            "catalog_version": record["catalogVersion"],
            "original_record_sha256": hashlib.sha256(canonical(record).encode()).hexdigest(),
        },
    }
    return package, warnings
