"""Exercise the installed debug app from outside its process on an isolated emulator.

Uses the real UI, private on-disk journal, process IDs and server receipts. No model inference.
Requires a running backend on port 8765. The CI emulator must have no user data.
"""

import json
import re
import shlex
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.request import urlopen

PACKAGE = "io.github.kuoforever.aiworkspace"
OUT = Path("android-evidence/process-recovery")


def adb(*args, check=True, content=None):
    return subprocess.run(
        ["adb", *args], input=content, capture_output=True, check=check, timeout=30
    ).stdout


def hierarchy():
    adb("shell", "uiautomator", "dump", "--compressed", "/sdcard/workspace-window.xml")
    data = adb("exec-out", "cat", "/sdcard/workspace-window.xml")
    (OUT / "last-window.xml").write_bytes(data)
    return ET.fromstring(data)


def node(tag, timeout=25, scroll=False):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            tree = hierarchy()
            for item in tree.iter("node"):
                if item.get("resource-id") == tag and item.get("enabled") == "true":
                    bounds = list(map(int, re.findall(r"\d+", item.get("bounds", ""))))
                    if len(bounds) == 4 and bounds[2] > bounds[0] and bounds[3] > bounds[1]:
                        return item
            if scroll:
                # Derive swipe coordinates from the observed hierarchy's screen extent.
                rects = [
                    list(map(int, re.findall(r"\d+", x.get("bounds", ""))))
                    for x in tree.iter("node")
                ]
                width = max(r[2] for r in rects if len(r) == 4)
                height = max(r[3] for r in rects if len(r) == 4)
                adb(
                    "shell",
                    "input",
                    "swipe",
                    str(width // 2),
                    str(height * 3 // 4),
                    str(width // 2),
                    str(height // 3),
                    "300",
                )
        except (ET.ParseError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.4)
    raise AssertionError(f"UI control unavailable: {tag}")


def tap(tag, scroll=False):
    item = node(tag, scroll=scroll)
    left, top, right, bottom = map(int, re.findall(r"\d+", item.get("bounds")))
    adb("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))


def type_text(tag, text):
    tap(tag)
    adb("shell", "input", "keycombination", "113", "29")  # Ctrl+A, Android 15.
    adb("shell", "input", "text", text.replace(" ", "%s"))
    adb("shell", "input", "keyevent", "4")  # Close the focused keyboard.


def wait_text(tag, text, timeout=35):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if text in node(tag).get("text", ""):
            return
        time.sleep(0.5)
    raise AssertionError(f"Expected {tag} to contain {text}")


def screenshot(name):
    (OUT / f"{name}.png").write_bytes(adb("exec-out", "screencap", "-p"))


def restart():
    old = adb("shell", "pidof", PACKAGE, check=False).decode().strip()
    adb("shell", "am", "force-stop", PACKAGE)
    assert not adb("shell", "pidof", PACKAGE, check=False).strip()
    adb("shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity")
    new = adb("shell", "pidof", PACKAGE).decode().strip()
    assert new and new != old, (old, new)
    return {"before_pid": old, "after_pid": new}


def journal():
    return adb("exec-out", "run-as", PACKAGE, "cat", "files/pending-command.json")


def write_journal(data):
    command = f"run-as {PACKAGE} sh -c {shlex.quote('cat > files/pending-command.json')}"
    adb("shell", command, content=data)


def get(path):
    with urlopen("http://127.0.0.1:8765/api" + path, timeout=15) as response:
        return json.load(response)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    assert adb("shell", "getprop", "ro.kernel.qemu").strip() == b"1", "Use an isolated emulator"
    adb("reverse", "tcp:8765", "tcp:8765")
    restart()
    title = "ProcessRecovery-" + uuid.uuid4().hex[:10]
    tap("new-review")
    tap("fill-example")
    type_text("title", title)
    draft_restart = restart()
    tap("new-review")
    assert title in node("title").get("text", ""), "Draft lost after process termination"

    # Send from the UI while disconnected so the durable command has an unknown result.
    adb("reverse", "--remove", "tcp:8765")
    tap("submit", scroll=True)
    node("retry-command", timeout=35)
    original = json.loads(journal())
    assert original["key"] and json.loads(original["body"])["title"] == title
    screenshot("01-offline-pending")
    pending_restart = restart()
    node("retry-command", timeout=35)
    assert json.loads(journal()) == original
    assert not [r for r in get("/reviews") if r["title"] == title]

    adb("reverse", "tcp:8765", "tcp:8765")
    tap("check-connection")
    wait_text("connection-status", "工作台已连接")
    assert json.loads(journal()) == original, "Connection check must not acknowledge a write"
    tap("retry-command")
    wait_text("status", "等待补充")
    matches = [r for r in get("/reviews") if r["title"] == title]
    assert len(matches) == 1, matches
    review_id = matches[0]["id"]
    assert json.loads(journal()) is None

    answer = "Query payment status before retrying a confirmed failure."
    type_text("answer:q1", answer)
    answer_restart = restart()
    tap("review:" + review_id, scroll=True)
    assert answer in node("answer:q1").get("text", ""), "Answer lost after process termination"
    tap("answer-submit", scroll=True)
    wait_text("status", "已完成")
    saved = get("/reviews/" + review_id)
    assert saved["answers"]["q1"] == answer and saved["status"] == "completed"
    assert len([r for r in get("/reviews") if r["title"] == title]) == 1
    screenshot("02-restored-report")

    # Corrupt a settled journal; the app must stay open without silently treating it as empty.
    settled = journal()
    assert json.loads(settled) is None
    adb("shell", "am", "force-stop", PACKAGE)
    write_journal(b"{broken")
    try:
        corruption_restart = restart()
        wait_text("startup-error", "写入已暂停")
        assert journal() == b"{broken"
        screenshot("03-storage-recovery")
    finally:
        write_journal(settled)
    tap("reload-local")
    node("new-review")
    report = {
        "status": "passed",
        "model_inference": False,
        "review_id": review_id,
        "checks": [
            "draft_process_restart",
            "offline_command_process_restart",
            "connection_check_is_read_only",
            "single_record_after_retry",
            "answer_process_restart",
            "corrupt_journal_recovery",
        ],
        "restarts": [draft_restart, pending_restart, answer_restart, corruption_restart],
        "request_key": original["key"],
    }
    (OUT / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    finally:
        adb("reverse", "tcp:8765", "tcp:8765", check=False)
