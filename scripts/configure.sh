#!/usr/bin/env bash
# Writes Config/Local.xcconfig (never committed): your Apple team and the
# prefix of your bundle identifiers.
#
#   scripts/configure.sh <team id> <bundle prefix>
#   scripts/configure.sh ABCDE12345 com.example.plume
#
# The team id is under Membership on developer.apple.com, or:
#   security find-identity -v -p codesigning
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="${1:?usage: scripts/configure.sh <team id> <bundle prefix>}"
PREFIX="${2:?usage: scripts/configure.sh <team id> <bundle prefix>}"
cat > Config/Local.xcconfig <<CONF
DEVELOPMENT_TEAM = $TEAM
PLUME_BUNDLE_PREFIX = $PREFIX
CONF
echo "Config/Local.xcconfig written (team $TEAM, bundle prefix $PREFIX)."
echo "For an iPhone, create the app group group.$PREFIX on developer.apple.com"
echo "(Identifiers → App Groups) before the first device build."
