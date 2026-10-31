#!/usr/bin/env bash
# Generates Plume.xcodeproj from project.yml (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
echo "Plume.xcodeproj generated."
