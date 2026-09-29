#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swift Scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
xcodegen generate --spec project.yml
