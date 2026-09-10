#!/usr/bin/env bash

install_app() {
  local source_bundle="${1:-}"
  local destination_bundle="${2:-}"

  if [[ -z "$source_bundle" || -z "$destination_bundle" ]]; then
    printf '%s\n' "usage: install_app SOURCE_APP DESTINATION_APP" >&2
    return 2
  fi

  if [[ ! -d "$source_bundle" ]]; then
    printf 'source app does not exist: %s\n' "$source_bundle" >&2
    return 1
  fi

  if [[ "$source_bundle" == "$destination_bundle" ]]; then
    return 0
  fi

  local destination_parent
  destination_parent="$(dirname "$destination_bundle")"
  if ! mkdir -p "$destination_parent"; then
    printf 'cannot create app installation directory: %s\n' "$destination_parent" >&2
    return 1
  fi

  local staging_bundle="${destination_bundle}.updating.$$"
  rm -rf "$staging_bundle"

  if ! /usr/bin/ditto "$source_bundle" "$staging_bundle"; then
    rm -rf "$staging_bundle" || true
    printf 'cannot copy app to staging path: %s\n' "$staging_bundle" >&2
    return 1
  fi

  if ! rm -rf "$destination_bundle"; then
    rm -rf "$staging_bundle" || true
    printf 'cannot replace existing app: %s\n' "$destination_bundle" >&2
    return 1
  fi

  if ! mv "$staging_bundle" "$destination_bundle"; then
    rm -rf "$staging_bundle" || true
    printf 'cannot finish app installation: %s\n' "$destination_bundle" >&2
    return 1
  fi

  printf 'installed app: %s\n' "$destination_bundle"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "$#" -ne 2 ]]; then
    printf '%s\n' "usage: install_app SOURCE_APP DESTINATION_APP" >&2
    exit 2
  fi

  install_app "$1" "$2"
fi
