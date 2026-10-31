#!/usr/bin/env bash
# Starts a throwaway Nextcloud in Docker on 127.0.0.1:8099 and runs the
# package tests against it (the server tests are skipped without one).
#
#   scripts/test-server.sh          # start (if needed) and test
#   scripts/test-server.sh stop     # remove the container
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=plume-nextcloud-test
PASSWORD=plume-test-pass
if [[ "${1:-}" == stop ]]; then docker rm -f "$NAME" >/dev/null; exit; fi
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" -p 127.0.0.1:8099:80 \
    -e SQLITE_DATABASE=nc -e NEXTCLOUD_ADMIN_USER=admin -e NEXTCLOUD_ADMIN_PASSWORD="$PASSWORD" \
    -e NEXTCLOUD_TRUSTED_DOMAINS="localhost 127.0.0.1" nextcloud:35-apache >/dev/null
fi
echo -n "Waiting for Nextcloud"
until curl -sf http://127.0.0.1:8099/status.php | grep -q '"installed":true'; do echo -n .; sleep 3; done
echo
cd Packages/PlumeKit
PLUME_TEST_SERVER=http://127.0.0.1:8099 PLUME_TEST_USER=admin PLUME_TEST_PASSWORD="$PASSWORD" swift test
