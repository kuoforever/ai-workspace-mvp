#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" = 1
mkdir -p android-evidence/performance
bash scripts/mobile-performance-service.sh android
.venv/bin/python scripts/mobile-performance-fixture.py --out android-evidence/performance/fixture.json
# Only the isolated CI emulator is cleared; the benchmark target uses the local
# debug key but is non-debuggable and otherwise inherits the optimized release.
adb shell am force-stop io.github.kuoforever.aiworkspace
adb shell pm clear io.github.kuoforever.aiworkspace
bash android/gradlew -p android :benchmark:connectedBenchmarkAndroidTest --no-daemon --stacktrace \
    -Pandroid.testInstrumentationRunnerArguments.androidx.benchmark.suppressErrors=EMULATOR \
    >android-evidence/performance/benchmark.log 2>&1 || {
    tail -100 android-evidence/performance/benchmark.log; exit 1;
}
tail -50 android-evidence/performance/benchmark.log
.venv/bin/python scripts/mobile-performance-summary.py --platform android \
    --input android/benchmark/build/outputs --out android-evidence/performance/summary.json
