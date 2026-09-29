#!/usr/bin/env bash
set -euo pipefail
mkdir -p android-evidence
adb reverse tcp:8765 tcp:8765
adb shell screenrecord --time-limit 180 /sdcard/ai-workspace-ci.mp4 >android-evidence/recording.log 2>&1 &
recording_pid=$!
test_exit=0
bash android/gradlew -p android :app:connectedDebugAndroidTest --no-daemon --stacktrace || test_exit=$?
adb shell pkill -INT screenrecord || true
wait "$recording_pid" || true
adb pull /sdcard/ai-workspace-ci.mp4 android-evidence/ci-demo.mp4 || true
adb pull /sdcard/Android/data/io.github.kuoforever.aiworkspace/files/screenshots android-evidence/screenshots || true
exit "$test_exit"
