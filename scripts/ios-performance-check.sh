#!/usr/bin/env bash
set -euo pipefail
simulator_id="$1"
mkdir -p ios-evidence/performance
if [ "${GITHUB_ACTIONS:-}" = true ]; then bash scripts/mobile-performance-service.sh ios; fi
.venv/bin/python scripts/mobile-performance-fixture.py --out ios-evidence/performance/fixture.json
xcodebuild build-for-testing -configuration Release -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath ios/build/performance \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ENABLE_TESTABILITY=YES -enableCodeCoverage NO -parallel-testing-enabled NO \
    >ios-evidence/performance/build.log 2>&1 || { tail -100 ios-evidence/performance/build.log; exit 1; }
xcodebuild -configuration Release -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath ios/build/performance \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO ENABLE_TESTABILITY=YES -enableCodeCoverage NO \
    -showBuildSettings >ios-evidence/performance/build-settings.txt
lipo -archs ios/build/performance/Build/Products/Release-iphonesimulator/AIWorkspace.app/AIWorkspace \
    >ios-evidence/performance/architectures.txt
ditto -c -k --sequesterRsrc --keepParent ios/build/performance/Build/Products/Release-iphonesimulator/AIWorkspace.app \
    ios-evidence/performance/AIWorkspace-release-simulator.app.zip
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
for app_bundle in AIWorkspace.app AIWorkspaceUITests-Runner.app; do
    xcrun simctl install "$simulator_id" "ios/build/performance/Build/Products/Release-iphonesimulator/$app_bundle"
done
xcodebuild test-without-building -configuration Release -project ios/AIWorkspace.xcodeproj -scheme AIWorkspace \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath ios/build/performance \
    -only-testing:AIWorkspaceTests/DocumentPerformanceTests -only-testing:AIWorkspaceUITests/LaunchPerformanceTests \
    -resultBundlePath ios-evidence/performance/Performance.xcresult -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO -enableCodeCoverage NO >ios-evidence/performance/tests.log 2>&1 || {
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
