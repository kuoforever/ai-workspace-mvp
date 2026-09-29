"""Verify a committed Git snapshot in a fresh directory and virtual environment."""

import argparse
import json
import os
import platform
import shutil
import subprocess
import tempfile
import time
import zipfile
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    uv = shutil.which("uv")
    node = shutil.which("node")
    if not uv or not node:
        raise SystemExit("uv and Node.js must be on PATH")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    result = {
        "verified_at": datetime.now(UTC).isoformat(),
        "revision": revision,
        "platform": platform.platform(),
        "scope": "fresh Git archive and new Python 3.12 venv; package download cache may be reused",
        "model_calls": 0,
        "steps": [],
    }
    with tempfile.TemporaryDirectory(prefix="release-check-", dir=args.work_dir) as scratch:
        scratch = Path(scratch).resolve()
        archive = scratch / "source.zip"
        subprocess.run(
            ["git", "archive", "--format=zip", "--output", str(archive), revision],
            cwd=ROOT,
            check=True,
        )
        checkout = scratch / "checkout"
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(checkout)
        assert not (checkout / ".venv").exists() and not (checkout / "data").exists()
        # Do not inherit the caller's venv or local app database.
        env = {
            k: v
            for k, v in os.environ.items()
            if k
            not in (
                "VIRTUAL_ENV",
                "UV_PROJECT_ENVIRONMENT",
                "AI_WORKSPACE_DATA",
                "AI_WORKSPACE_URL",
            )
        }
        env["PYTHONUTF8"] = "1"
        commands = [
            [uv, "sync", "--frozen", "--python", "3.12"],
            [uv, "run", "--no-sync", "ruff", "check", "app", "tests", "scripts", "evals"],
            [node, "--check", "static/ai-review-ui.js"],
            [uv, "run", "--no-sync", "python", "-m", "evals.benchmark", "freeze"],
            [uv, "run", "--no-sync", "pytest", "-q"],
        ]
        for command in commands:
            started = time.monotonic()
            completed = subprocess.run(
                command,
                cwd=checkout,
                env=env,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            step = {
                "command": [Path(command[0]).name, *command[1:]],
                "exit_code": completed.returncode,
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "output": completed.stdout.strip(),
            }
            result["steps"].append(step)
            print("PASS" if completed.returncode == 0 else "FAIL", " ".join(step["command"]))
            if completed.returncode:
                break
        result["passed"] = len(result["steps"]) == len(commands) and all(
            step["exit_code"] == 0 for step in result["steps"]
        )
        # Keep environment-specific absolute paths out of the published report.
        for step in result["steps"]:
            step["output"] = step["output"].replace(str(scratch), "<temporary-release-dir>")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Saved", args.out)
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
