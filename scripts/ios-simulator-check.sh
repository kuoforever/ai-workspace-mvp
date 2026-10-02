#!/usr/bin/env bash
set -euo pipefail
mkdir -p ios-evidence
xcodebuild -version | tee ios-evidence/xcode-version.txt
xcodegen --version | tee ios-evidence/xcodegen-version.txt
xcrun simctl list devices available --json >ios-evidence/devices.json
device_id=$(.venv/bin/python -c 'import json; d=json.load(open("ios-evidence/devices.json")); print(next(v["udid"] for k,rows in d["devices"].items() if k.endswith("iOS-18-5") for v in rows if v["name"]=="iPhone 16"))')
printf '%s\n' "$device_id" >ios-evidence/device-id.txt
bash ios/generate.sh
xcodebuild build-for-testing -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath ios/build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO -parallel-testing-enabled NO >ios-evidence/build.log 2>&1 || {
    tail -100 ios-evidence/build.log; exit 1;
  }
lipo -archs ios/build/Build/Products/Debug-iphonesimulator/AIWorkspace.app/AIWorkspace >ios-evidence/architectures.txt
ditto -c -k --sequesterRsrc --keepParent ios/build/Build/Products/Debug-iphonesimulator/AIWorkspace.app ios-evidence/AIWorkspace-simulator.app.zip
xcrun simctl boot "$device_id" || true
xcrun simctl bootstatus "$device_id" -b
# Register both bundles before XCTest starts, including on newly created devices.
# Boot completion alone does not guarantee FrontBoard knows the test runner.
install_test_apps() {
  local test_simulator_id="$1"
  local test_products="ios/build/Build/Products/Debug-iphonesimulator"
  xcrun simctl install "$test_simulator_id" "$test_products/AIWorkspace.app"
  xcrun simctl install "$test_simulator_id" "$test_products/AIWorkspaceUITests-Runner.app"
  xcrun simctl get_app_container "$test_simulator_id" io.github.kuoforever.aiworkspace.ios app >/dev/null
  xcrun simctl get_app_container "$test_simulator_id" io.github.kuoforever.aiworkspace.ios.uitests.xctrunner app >/dev/null
}
install_test_apps "$device_id"
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
if [ "$test_exit" -ne 0 ]; then
  .venv/bin/python -c 'import json; print(json.dumps(json.load(open("ios-evidence/test-summary.json"))["testFailures"], ensure_ascii=False))'
fi
xcrun xcresulttool export attachments --path ios-evidence/Tests.xcresult --output-path ios-evidence/screenshots
if [ "$test_exit" -eq 0 ]; then
  test -s ios-evidence/AIWorkspace-simulator.app.zip
  test -s ios-evidence/ci-demo.mp4
fi
if [ "$test_exit" -ne 0 ]; then exit "$test_exit"; fi

# Reuse the compiled application on a compact phone and a tablet. Real simulator
# settings exercise Dynamic Type and dark appearance without app-only test hooks.
runtime_id=$(.venv/bin/python -c 'import json; d=json.load(open("ios-evidence/devices.json")); print(next(k for k in d["devices"] if k.endswith("iOS-18-5")))')
compact_id=$(xcrun simctl create "AI Workspace compact check" com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation "$runtime_id")
tablet_id=$(.venv/bin/python -c 'import json; d=json.load(open("ios-evidence/devices.json")); print(next(v["udid"] for k,rows in d["devices"].items() if k.endswith("iOS-18-5") for v in rows if v["name"].startswith("iPad")))')
xcrun simctl shutdown "$device_id"
for profile in compact tablet; do
  if [ "$profile" = compact ]; then layout_id="$compact_id"; else layout_id="$tablet_id"; fi
  xcrun simctl boot "$layout_id"
  xcrun simctl bootstatus "$layout_id" -b
  install_test_apps "$layout_id"
  old_appearance=$(xcrun simctl ui "$layout_id" appearance | tr '[:upper:]' '[:lower:]')
  old_content_size=$(xcrun simctl ui "$layout_id" content_size)
  xcrun simctl ui "$layout_id" appearance dark
  xcrun simctl ui "$layout_id" content_size accessibility-extra-extra-extra-large
  {
    printf 'Device: %s\n' "$layout_id"
    xcrun simctl ui "$layout_id" appearance
    xcrun simctl ui "$layout_id" content_size
  } >"ios-evidence/layout-$profile-settings.txt"
  layout_exit=0
  xcodebuild test-without-building -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$layout_id" -derivedDataPath ios/build \
    -only-testing:AIWorkspaceUITests/WorkspaceFlowTests/testLayoutKeepsDraftAndSubmitReachableAfterRotation \
    -resultBundlePath "ios-evidence/Layout-$profile.xcresult" -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO >"ios-evidence/layout-$profile.log" 2>&1 || layout_exit=$?
  tail -60 "ios-evidence/layout-$profile.log"
  xcrun xcresulttool get test-results summary --path "ios-evidence/Layout-$profile.xcresult" >"ios-evidence/layout-$profile-summary.json"
  if [ "$layout_exit" -ne 0 ]; then
    .venv/bin/python -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["testFailures"], ensure_ascii=False))' "ios-evidence/layout-$profile-summary.json"
  fi
  xcrun xcresulttool export attachments --path "ios-evidence/Layout-$profile.xcresult" --output-path "ios-evidence/layout-$profile-screenshots"
  xcrun simctl ui "$layout_id" content_size "$old_content_size"
  xcrun simctl ui "$layout_id" appearance "$old_appearance"
  xcrun simctl shutdown "$layout_id"
  if [ "$layout_exit" -ne 0 ]; then exit "$layout_exit"; fi
done
xcrun simctl delete "$compact_id"
