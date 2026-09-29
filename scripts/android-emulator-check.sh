#!/usr/bin/env bash
set -euo pipefail
mkdir -p android-evidence
pull_evidence() {
    # The emulator can briefly disconnect after recording stops. Retry copying
    # evidence, never the application commands or test cases.
    for attempt in 1 2 3; do
        if timeout 20s adb wait-for-device && timeout 30s adb pull "$1" "$2"; then
            return 0
        fi
        sleep 2
    done
    return 1
}
adb reverse tcp:8765 tcp:8765
# The shell-owned temporary directory avoids Android shared-media write policy.
adb shell screenrecord --size 720x1280 --bit-rate 2000000 --time-limit 180 /data/local/tmp/ai-workspace-demo.mp4 >android-evidence/recording.log 2>&1 &
recording_pid=$!
test_exit=0
bash android/gradlew -p android :app:connectedDebugAndroidTest --no-daemon --stacktrace || test_exit=$?
adb shell pkill -INT screenrecord || true
wait "$recording_pid" || true
pull_evidence /data/local/tmp/ai-workspace-demo.mp4 android-evidence/ci-demo.mp4 || true
pull_evidence /sdcard/Pictures/ai-workspace-evidence android-evidence/screenshots || true
cat android-evidence/recording.log
if [ "$test_exit" -eq 0 ]; then
    test -s android-evidence/screenshots/02-report.png
    test -s android-evidence/ci-demo.mp4
fi
exit "$test_exit"
