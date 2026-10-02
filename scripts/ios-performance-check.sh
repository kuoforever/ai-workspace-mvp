#!/usr/bin/env bash
set -euo pipefail
mkdir -p ios-evidence/performance
xcodebuild -version >ios-evidence/performance/xcode-version.txt
xcodegen --version >ios-evidence/performance/xcodegen-version.txt
xcrun simctl list devices available --json >ios-evidence/performance/devices.json
simulator_id="${1:-}"
if [ -z "$simulator_id" ]; then
    simulator_id=$(.venv/bin/python -c 'import json; d=json.load(open("ios-evidence/performance/devices.json")); print(next(v["udid"] for k,rows in d["devices"].items() if k.endswith("iOS-18-5") for v in rows if v["name"]=="iPhone 16"))')
fi
printf '%s\n' "$simulator_id" >ios-evidence/performance/device-id.txt
bash ios/generate.sh
if [ "${GITHUB_ACTIONS:-}" = true ]; then bash scripts/mobile-performance-service.sh ios; fi
.venv/bin/python scripts/mobile-performance-fixture.py --out ios-evidence/performance/fixture.json
xcodebuild build-for-testing -configuration Release -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath ios/build/performance \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ENABLE_TESTABILITY=YES ENABLE_CODE_COVERAGE=NO -enableCodeCoverage NO -parallel-testing-enabled NO \
    >ios-evidence/performance/build.log 2>&1 || { tail -100 ios-evidence/performance/build.log; exit 1; }
xcodebuild -configuration Release -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath ios/build/performance \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ENABLE_TESTABILITY=YES ENABLE_CODE_COVERAGE=NO \
    -showBuildSettings >ios-evidence/performance/build-settings.txt
lipo -archs ios/build/performance/Build/Products/Release-iphonesimulator/AIWorkspace.app/AIWorkspace \
    >ios-evidence/performance/architectures.txt
ditto -c -k --sequesterRsrc --keepParent ios/build/performance/Build/Products/Release-iphonesimulator/AIWorkspace.app \
    ios-evidence/performance/AIWorkspace-release-simulator.app.zip
xcrun simctl boot "$simulator_id" || true
xcrun simctl bootstatus "$simulator_id" -b
if [ "${GITHUB_ACTIONS:-}" = true ]; then
    # Keep the default full run and a standalone measurement comparable. Remove
    # only this app's data on the ephemeral CI simulator, after functional tests.
    if xcrun simctl get_app_container "$simulator_id" io.github.kuoforever.aiworkspace.ios app >/dev/null 2>&1; then
        xcrun simctl uninstall "$simulator_id" io.github.kuoforever.aiworkspace.ios
    fi
    printf '%s\n' 'fresh-app-data-on-isolated-ci-simulator' >ios-evidence/performance/app-data-state.txt
fi
for app_bundle in AIWorkspace.app AIWorkspaceUITests-Runner.app; do
    xcrun simctl install "$simulator_id" "ios/build/performance/Build/Products/Release-iphonesimulator/$app_bundle"
done
xcodebuild test-without-building -configuration Release -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath ios/build/performance \
    -only-testing:AIWorkspaceTests/DocumentPerformanceTests -only-testing:AIWorkspaceUITests/LaunchPerformanceTests \
    -resultBundlePath ios-evidence/performance/Performance.xcresult -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO -enableCodeCoverage NO >ios-evidence/performance/tests.log 2>&1 || {
    tail -100 ios-evidence/performance/tests.log; exit 1;
}
xcrun xcresulttool get test-results summary --path ios-evidence/performance/Performance.xcresult \
    >ios-evidence/performance/test-summary.json
# Keep native metrics when supported by the installed Xcode, plus the original
# log and result bundle. The summarizer requires real measurement samples.
xcrun xcresulttool get test-results metrics --path ios-evidence/performance/Performance.xcresult \
    >ios-evidence/performance/metrics.json 2>ios-evidence/performance/metrics-export.log || true
.venv/bin/python scripts/mobile-performance-summary.py --platform ios \
    --input ios-evidence/performance/tests.log --out ios-evidence/performance/summary.json
tail -60 ios-evidence/performance/tests.log
xcrun simctl shutdown "$simulator_id"
