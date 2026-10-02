"""Keep measured simulator samples and descriptive percentiles, without a speed gate."""

import argparse
import json
import math
import re
from pathlib import Path


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def describe(values: list[float], *, allow_negative: bool = False) -> dict:
    if len(values) < 5 or any(
        not math.isfinite(value) or (value < 0 and not allow_negative) for value in values
    ):
        raise ValueError("Expected at least five finite measured samples; time cannot be negative")
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
        "samples": values,
    }


def android_measurements(root: Path) -> tuple[list[dict], list[dict]]:
    measurements, contexts = [], []
    for path in sorted(root.rglob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, UnicodeError):
            continue
        if not isinstance(data, dict) or not data.get("benchmarks"):
            continue
        contexts.append({"file": str(path.relative_to(root)), "context": data.get("context")})
        for benchmark in data["benchmarks"]:
            for group in ("metrics", "sampledMetrics"):
                for name, metric in benchmark.get(group, {}).items():
                    runs = metric.get("runs", [])
                    samples = [
                        float(value)
                        for run in runs
                        for value in (run if isinstance(run, list) else [run])
                    ]
                    measurements.append(
                        {
                            "test": benchmark["name"],
                            "metric": name,
                            "source": str(path.relative_to(root)),
                            "group": group,
                            "iterations": len(runs),
                            # A negative overrun means the frame met its deadline.
                            **describe(samples, allow_negative=name == "frameOverrunMs"),
                        }
                    )
    return measurements, contexts


def ios_measurements(path: Path) -> list[dict]:
    measurements = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if " measured [" not in line:
            continue
        match = re.search(r"measured \[(.*?)\].*?values:\s*\[([^]]+)\]", line)
        if match:
            values = [float(value.strip()) for value in match[2].split(",")]
            measurements.append(
                {
                    "test": line.split(" measured [", 1)[0],
                    "metric": match[1],
                    "source": path.name,
                    **describe(values, allow_negative="memory" in match[1].casefold()),
                }
            )
    return measurements


def summarize(platform: str, source: Path) -> dict:
    if platform == "android":
        measurements, contexts = android_measurements(source)
        expected = ("coldLaunch", "pasteEightThousandCharacters", "scrollTwentyReviewRows")
    else:
        measurements, contexts = ios_measurements(source), []
        expected = (
            "testColdApplicationLaunch",
            "testEightThousandCharacterImportQuoteAndExport",
            "testTwentyFullReportCacheReloads",
        )
    if not all(any(name in entry["test"] for entry in measurements) for name in expected):
        raise ValueError("Missing measured workload; do not report an empty or partial benchmark")
    return {
        "schema_version": 1,
        "platform": platform,
        "environment": "simulator",
        "configuration": "optimized, code coverage disabled for iOS performance",
        "interpretation": "Descriptive baseline; not real-device performance, no cross-platform ranking",
        "percentile_method": "linear interpolation over saved samples",
        "contexts": contexts,
        "measurements": measurements,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("android", "ios"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = summarize(args.platform, args.input)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
