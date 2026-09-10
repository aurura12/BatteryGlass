#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_FILE="$ROOT_DIR/Sources/BatteryGlass/App/BatteryGlassApp.swift"
SETTINGS_FILE="$ROOT_DIR/Sources/BatteryGlass/Stores/AppSettings.swift"
LABEL_FILE="$ROOT_DIR/Sources/BatteryGlass/Views/MenuBarLabel.swift"
EXTENSIONS_FILE="$ROOT_DIR/Sources/BatteryGlass/Support/Extensions.swift"

if ! rg -q 'MenuBarExtra' "$APP_FILE"; then
  printf '%s\n' "menu_bar_only_test: MenuBarExtra is missing" >&2
  exit 1
fi

if rg -n 'WindowGroup|applicationShouldHandleReopen|showMainWindowAtLaunch|shouldShowMainWindowAtLaunch' \
  "$APP_FILE" "$SETTINGS_FILE"; then
  printf '%s\n' "menu_bar_only_test: main-window entry points still exist" >&2
  exit 1
fi

if rg -n 'requestDashboardWindow' "$LABEL_FILE" "$EXTENSIONS_FILE"; then
  printf '%s\n' "menu_bar_only_test: main-window notification path still exists" >&2
  exit 1
fi

printf '%s\n' "menu_bar_only_test: PASS"
