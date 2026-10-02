"""Inspect all five captured Android iterations without treating nested slices as CPU time."""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path

from perfetto.trace_processor import TraceProcessor

QUERY = """
SELECT t.name AS thread,
       CASE WHEN s.name GLOB 'Choreographer#doFrame*' THEN 'Choreographer#doFrame'
            WHEN s.name GLOB 'DrawFrames*' THEN 'DrawFrames' ELSE s.name END AS label,
       COUNT(*) AS n, AVG(s.dur)/1000000.0 AS average_ms,
       MAX(s.dur)/1000000.0 AS max_ms, SUM(s.dur)/1000000.0 AS total_ms
FROM slice s JOIN thread_track tt ON s.track_id=tt.id
JOIN thread t ON t.utid=tt.utid JOIN process p ON p.upid=t.upid
WHERE p.name='io.github.kuoforever.aiworkspace' AND s.dur>0
GROUP BY t.name,label ORDER BY total_ms DESC LIMIT 20
"""


def analyze(root: Path) -> dict:
    root = root.resolve()
    # Artifact extraction can exceed Windows' legacy path limit.
    if os.name == "nt" and not str(root).startswith("\\\\?\\"):
        root = Path("\\\\?\\" + str(root))
    iterations = []
    for workload in ("scrollTwentyReviewRows", "pasteEightThousandCharacters"):
        traces = sorted(root.rglob(f"WorkspaceBenchmark_{workload}_iter*_*.perfetto-trace"))
        if len(traces) != 5:
            raise ValueError(f"Expected all five iteration traces for {workload}, got {len(traces)}")
        for trace in traces:
            with trace.open("rb") as stream, TraceProcessor(trace=stream) as processor:
                slices = [
                    {
                        "thread": row.thread,
                        "slice": row.label,
                        "count": row.n,
                        "average_ms": row.average_ms,
                        "max_ms": row.max_ms,
                        "total_ms": row.total_ms,
                    }
                    for row in processor.query(QUERY)
                ]
            with trace.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            iterations.append(
                {"workload": workload, "trace": trace.name, "sha256": digest, "slices": slices}
            )
    return {
        "schema_version": 1,
        "perfetto_python_version": importlib.metadata.version("perfetto"),
        "window": "Entire collected iteration trace, not FrameTimingMetric's selected-frame window",
        "interpretation": "Nested wall-clock slices; totals overlap and must not be added or called CPU usage",
        "query": QUERY,
        "iterations": iterations,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.input)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
