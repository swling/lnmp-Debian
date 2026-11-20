#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-${SCRIPT_DIR}/lnmp}"
TARGET=/usr/local/bin/lnmp
ALIAS=/usr/bin/lnmp

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ $# -le 1 ]] || fail "Usage: sync-lnmp.sh [source-lnmp-script]"
[[ "$(id -u)" -eq 0 ]] || fail "Run this command as root."
[[ -f "$SOURCE" && -r "$SOURCE" ]] || fail "Source script not found or unreadable: $SOURCE"
bash -n "$SOURCE" || fail "Source script has a Bash syntax error: $SOURCE"

if [[ -L "$TARGET" ]]; then
    fail "${TARGET} is a symlink; refusing to replace it."
fi
if [[ -e "$ALIAS" && ! -L "$ALIAS" ]]; then
    fail "${ALIAS} is not a symlink; refusing to replace it."
fi
if [[ -L "$ALIAS" ]] &&
   [[ "$(readlink -f "$ALIAS" 2>/dev/null || true)" != "$TARGET" ]]; then
    fail "${ALIAS} points somewhere other than ${TARGET}."
fi

temporary="$(mktemp /usr/local/bin/.lnmp.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
install -m 0755 "$SOURCE" "$temporary"
mv -f "$temporary" "$TARGET"
trap - EXIT

if [[ -L "$ALIAS" ]]; then
    printf 'Verified command alias: %s -> %s\n' "$ALIAS" "$TARGET"
else
    ln -s "$TARGET" "$ALIAS"
fi

printf 'Updated lnmp command from %s\n' "$SOURCE"
printf 'Installed command: %s (accessible as %s)\n' "$TARGET" "$ALIAS"
