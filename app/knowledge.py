import hashlib
import json
from pathlib import Path

from .schemas import ModelOutput

ROOT = Path(__file__).resolve().parents[1]


def canonical(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value) -> str:
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def source(source_id, title, text, path, **extra):
    return {
        "id": source_id,
        "title": title,
        "text": text,
        "path": path,
        "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        **extra,
    }


class Knowledge:
    def __init__(self, path=ROOT / "knowledge" / "catalog.json"):
        self.catalog = json.loads(path.read_text(encoding="utf-8"))
        self.checks = {c["id"]: c for c in self.catalog["checks"]}
        self.version = self.catalog["version"]
        self.hash = digest(self.catalog)

    def public_catalog(self):
        return {
            "version": self.version,
            "sha256": self.hash,
            "checks": [
                {k: c[k] for k in ("id", "question", "groupName", "topic")}
                for c in self.checks.values()
            ],
        }

    def retrieve(self, data):
        if any(i not in self.checks for i in data["check_ids"]):
            raise ValueError("包含不存在的检查项")
        result = {"input": source("input", "提交的设计", data["design"], "input.txt")}
        topics = set()
        for cid in data["check_ids"]:
            c = self.checks[cid]
            text = "\n".join(f"{k}: {c[k]}" for k in ("question", "trigger", "evidence", "why"))
            result[cid] = source(
                cid, c["question"], text, f"专题/{c['topic']}/检查项.json", check_id=cid
            )
            topics.add(c["topic"])
        # A bounded deterministic excerpt per topic. Do not send the full manual.
        for topic in sorted(topics):
            docs = [
                d for d in self.catalog["docs"] if d["topic"] == topic and d["kind"] == "chapter"
            ]
            if docs:
                d = docs[0]
                lines, size = [], 0
                for line in d["text"].splitlines():
                    if size + len(line) > 650:
                        break
                    lines.append(line)
                    size += len(line) + 1
                if lines:
                    result[d["id"]] = source(
                        d["id"],
                        d["title"],
                        "\n".join(lines),
                        d["path"],
                        line_start=1,
                        line_end=len(lines),
                        doc_id=d["id"],
                    )
        # At most two relevant decision summaries; the full options remain in the original UI.
        for d in [d for d in self.catalog["decisions"] if d["topic"] in topics][:2]:
            text = (
                d["question"]
                + "\n"
                + "\n".join(
                    f"{o['name']}：{o['when']}；代价：{o['cost']}" for o in d["options"][:3]
                )
            )
            result[d["id"]] = source(d["id"], d["title"], text, f"专题/{d['topic']}/决策目录.json")
        return result


def add_answer_sources(sources, questions, answers):
    result = dict(sources)
    for q in questions:
        sid = "answer:" + q["id"]
        result[sid] = source(sid, q["text"], answers[q["id"]], f"answers/{q['id']}.txt")
    return result


def validate_output(output: ModelOutput, check_ids, sources, allow_questions):
    ids = set(check_ids)
    if output.kind == "questions":
        if not allow_questions or not output.questions or output.findings:
            raise ValueError("invalid_question_round")
        if len({q.id for q in output.questions}) != len(output.questions):
            raise ValueError("duplicate_question")
        if any(q.check_id not in ids for q in output.questions):
            raise ValueError("unknown_question_check")
        return
    if output.questions or len(output.findings) != len(ids):
        raise ValueError("incomplete_coverage")
    if {f.check_id for f in output.findings} != ids:
        raise ValueError("incomplete_coverage")
    for f in output.findings:
        cited = set()
        for cite in f.citations:
            s = sources.get(cite.source_id)
            if not s or cite.quote not in s["text"]:
                raise ValueError("invalid_citation")
            if hashlib.sha256(s["text"].encode("utf-8")).hexdigest() != s["sha256"]:
                raise ValueError("source_digest_mismatch")
            cited.add(cite.source_id)
        if f.check_id not in cited:
            raise ValueError("missing_check_citation")
        if f.verdict in ("supported", "risk", "not_applicable") and not any(
            s == "input" or s.startswith("answer:") for s in cited
        ):
            raise ValueError("missing_design_evidence")
