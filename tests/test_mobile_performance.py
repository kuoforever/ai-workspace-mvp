import json
import runpy
from pathlib import Path

import pytest

HELPER = runpy.run_path(str(Path(__file__).parents[1] / "scripts/mobile-performance-summary.py"))


def test_simulator_percentiles_keep_the_original_samples():
    values = [1.0, 2.0, 3.0, 4.0, 5.0]
    result = HELPER["describe"](values)
    assert result["p50"] == 3.0
    assert result["p95"] == pytest.approx(4.8)
    assert result["samples"] == values


@pytest.mark.parametrize("values", [[1, 2], [1, 2, 3, 4, float("nan")], [1, 2, 3, 4, -1]])
def test_invalid_measurements_cannot_become_a_successful_report(values):
    with pytest.raises(ValueError):
        HELPER["describe"](values)


def test_android_keeps_per_iteration_and_per_frame_samples(tmp_path):
    data = {
        "context": {"build": {"model": "emulator"}},
        "benchmarks": [
            {
                "name": name,
                "metrics": {"timeToInitialDisplayMs": {"runs": [1, 2, 3, 4, 5]}},
                "sampledMetrics": {"frameDurationCpuMs": {"runs": [[1, 2], [3, 4, 5]]}},
            }
            for name in ["coldLaunch", "pasteEightThousandCharacters", "scrollTwentyReviewRows"]
        ],
    }
    (tmp_path / "benchmarkData.json").write_text(json.dumps(data), encoding="utf-8")
    result = HELPER["summarize"]("android", tmp_path)
    assert result["environment"] == "simulator"
    assert len(result["measurements"]) == 6
    assert result["measurements"][1]["iterations"] == 2
    assert result["measurements"][1]["samples"] == [1, 2, 3, 4, 5]


def test_ios_requires_all_measured_workloads(tmp_path):
    log = tmp_path / "tests.log"
    names = [
        "testColdApplicationLaunch",
        "testEightThousandCharacterImportQuoteAndExport",
        "testTwentyFullReportCacheReloads",
    ]
    lines = [
        f"Test Case '-[PerformanceTests {name}]' measured [Time, seconds] "
        "average: 0.003, relative standard deviation: 10%, values: [0.001, 0.002, 0.003, 0.004, 0.005]"
        for name in names
    ]
    log.write_text("\n".join(lines), encoding="utf-8")
    result = HELPER["summarize"]("ios", log)
    assert len(result["measurements"]) == 3
    assert result["measurements"][0]["p50"] == 0.003
    log.write_text(lines[0], encoding="utf-8")
    with pytest.raises(ValueError, match="Missing measured workload"):
        HELPER["summarize"]("ios", log)
