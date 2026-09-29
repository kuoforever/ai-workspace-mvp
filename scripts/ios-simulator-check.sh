#!/usr/bin/env bash
set -euo pipefail
mkdir -p ios-evidence
xcodebuild -version | tee ios-evidence/xcode-version.txt
xcodegen --version | tee ios-evidence/xcodegen-version.txt
xcrun simctl list devices available --json >ios-evidence/devices.json
device_id=$(.venv/bin/python -c 'import json; d=json.load(open("ios-evidence/devices.json")); print(next(v["udid"] for k,rows in d["devices"].items() if k.endswith("iOS-18-5") for v in rows if v["name"]=="iPhone 16"))')
printf '%s\n' "$device_id" >ios-evidence/device-id.txt
xcrun simctl boot "$device_id" || true
xcrun simctl bootstatus "$device_id" -b
bash ios/generate.sh
xcodebuild build-for-testing -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath ios/build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO -parallel-testing-enabled NO >ios-evidence/build.log 2>&1 || {
    tail -100 ios-evidence/build.log; exit 1;
  }
lipo -archs ios/build/Build/Products/Debug-iphonesimulator/AIWorkspace.app/AIWorkspace >ios-evidence/architectures.txt
ditto -c -k --sequesterRsrc --keepParent ios/build/Build/Products/Debug-iphonesimulator/AIWorkspace.app ios-evidence/AIWorkspace-simulator.app.zip
xcrun simctl io "$device_id" recordVideo --codec=h264 ios-evidence/ci-demo.mp4 >ios-evidence/recording.log 2>&1 &
recording_pid=$!
finish_recording() {
  kill -INT "$recording_pid" 2>/dev/null || true
  wait "$recording_pid" || true
}
trap finish_recording EXIT
test_exit=0
xcodebuild test-without-building -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath ios/build \
  -resultBundlePath ios-evidence/Tests.xcresult -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO >ios-evidence/tests.log 2>&1 || test_exit=$?
finish_recording
trap - EXIT
tail -100 ios-evidence/tests.log
xcrun xcresulttool get test-results summary --path ios-evidence/Tests.xcresult >ios-evidence/test-summary.json
xcrun xcresulttool export attachments --path ios-evidence/Tests.xcresult --output-path ios-evidence/screenshots
if [ "$test_exit" -eq 0 ]; then
  test -s ios-evidence/AIWorkspace-simulator.app.zip
  test -s ios-evidence/ci-demo.mp4
fi
exit "$test_exit"
