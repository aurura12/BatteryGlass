#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/batteryglass-install-test.XXXXXX")"
trap 'exit_code=$?; rm -rf "$TEST_ROOT"; exit "$exit_code"' EXIT

[[ -f "$ROOT_DIR/script/install_app.sh" ]] || {
  printf '%s\n' "install_app_test: install_app.sh is missing" >&2
  exit 1
}
source "$ROOT_DIR/script/install_app.sh"

SOURCE_APP="$TEST_ROOT/dist/BatteryGlass.app"
DEST_APP="$TEST_ROOT/Applications/BatteryGlass.app"
mkdir -p "$SOURCE_APP/Contents" "$DEST_APP/Contents"
printf '%s\n' "new binary" > "$SOURCE_APP/Contents/new.txt"
printf '%s\n' "stale file" > "$DEST_APP/Contents/stale.txt"

install_app "$SOURCE_APP" "$DEST_APP"

[[ -f "$DEST_APP/Contents/new.txt" ]]
[[ ! -e "$DEST_APP/Contents/stale.txt" ]]
[[ "$(<"$DEST_APP/Contents/new.txt")" == "new binary" ]]

printf '%s\n' "install_app_test: PASS"
