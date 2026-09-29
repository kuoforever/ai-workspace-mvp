import json
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from .knowledge import canonical


def now():
    return datetime.now(UTC).isoformat()


class Conflict(Exception):
    pass


class Store:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / "reviews.sqlite3"
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS reviews (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS commands (
                    key TEXT PRIMARY KEY, digest TEXT NOT NULL, review_id TEXT NOT NULL
                );
            """)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        try:
            db.execute("PRAGMA journal_mode=WAL")
            with db:
                yield db
        finally:
            db.close()

    def replay(self, key, body_digest):
        with self.connect() as db:
            row = db.execute(
                "SELECT digest, review_id FROM commands WHERE key=?", (key,)
            ).fetchone()
        if row:
            if row[0] != body_digest:
                raise Conflict("同一请求键不能用于不同内容")
            return self.get(row[1])

    def get(self, review_id):
        with self.connect() as db:
            row = db.execute("SELECT body FROM reviews WHERE id=?", (review_id,)).fetchone()
        if not row:
            raise KeyError(review_id)
        return json.loads(row[0])

    def list(self):
        with self.connect() as db:
            rows = db.execute("SELECT body FROM reviews ORDER BY rowid DESC LIMIT 100").fetchall()
        return [json.loads(row[0]) for row in rows]

    def save(self, review, command=None):
        review["updated_at"] = now()
        with self.connect() as db:
            db.execute(
                "INSERT INTO reviews(id,body) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body",
                (review["id"], canonical(review)),
            )
            if command:
                db.execute("INSERT INTO commands VALUES(?,?,?)", (*command, review["id"]))

    def interrupt_running(self):
        # No LIMIT: every unfinished operation must be marked, even with >100 historical reviews.
        with self.connect() as db:
            rows = db.execute("SELECT body FROM reviews").fetchall()
            for row in rows:
                review = json.loads(row[0])
                if review["status"] == "running":
                    review.update(
                        status="interrupted", error="进程中断；请新建一次评审", updated_at=now()
                    )
                    review["revision"] += 1
                    db.execute(
                        "UPDATE reviews SET body=? WHERE id=?", (canonical(review), review["id"])
                    )
