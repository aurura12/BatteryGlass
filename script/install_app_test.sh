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
# 成功后不得残留 staging / backup 目录。
if compgen -G "$DEST_APP.updating.*" >/dev/null || compgen -G "$DEST_APP.backup.*" >/dev/null; then
  printf '%s\n' "install_app_test: leftover staging/backup directory" >&2
  exit 1
fi

# 回滚：让"把新 bundle 就位"这一步的 mv 失败，旧 App 必须被完整恢复。
ROLLBACK_SOURCE="$TEST_ROOT/rollback/dist/BatteryGlass.app"
ROLLBACK_DEST="$TEST_ROOT/rollback/Applications/BatteryGlass.app"
mkdir -p "$ROLLBACK_SOURCE/Contents" "$ROLLBACK_DEST/Contents"
printf '%s\n' "new binary" > "$ROLLBACK_SOURCE/Contents/new.txt"
printf '%s\n' "old binary" > "$ROLLBACK_DEST/Contents/old.txt"

SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/mv" <<'SHIM'
#!/usr/bin/env bash
# 只让"移动 staging（含 .updating.）到目的地"这一步失败，其余 mv 放行。
for arg in "$@"; do
  case "$arg" in
    *.updating.*) exit 1 ;;
  esac
done
exec /bin/mv "$@"
SHIM
chmod +x "$SHIM_DIR/mv"

if PATH="$SHIM_DIR:$PATH" install_app "$ROLLBACK_SOURCE" "$ROLLBACK_DEST"; then
  printf '%s\n' "install_app_test: expected install to fail" >&2
  exit 1
fi

[[ -f "$ROLLBACK_DEST/Contents/old.txt" ]]
[[ ! -e "$ROLLBACK_DEST/Contents/new.txt" ]]

printf '%s\n' "install_app_test: PASS"
