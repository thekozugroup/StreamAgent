#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="${1:-$root/dist/StreamAgent-macOS.zip}"
source="${source%/}"
if [ "$#" -gt 1 ]; then printf 'Usage: %s [archive.zip | StreamAgent.app]\n' "$0" >&2; exit 2; fi
refuse_running() {
    if /usr/bin/pgrep -x StreamAgent >/dev/null; then
        printf 'StreamAgent is running. Quit it before installing. Nothing was replaced.\n' >&2
        exit 1
    fi
}
# Refuse before staging, and again immediately before touching the destination.
refuse_running
stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/streamagent-install.XXXXXX")"
handoff=""
destination=""
backup=""
old_moved=false
new_moved=false
cleanup() {
    status=$?
    trap - EXIT
    set +e
    if [ "$status" -ne 0 ]; then
        if [ "$new_moved" = true ] && [ -e "$destination" ]; then
            /bin/mv "$destination" "$stage/rejected-generated.app"
        fi
        if [ "$old_moved" = true ] && [ -e "$backup" ]; then
            if [ ! -e "$destination" ]; then /bin/mv "$backup" "$destination"; fi
            if [ -e "$backup" ]; then printf 'Previous app preserved at: %s\n' "$backup" >&2; fi
        fi
    fi
    if [ -n "$handoff" ]; then /bin/rm -rf "$handoff"; fi
    /bin/rm -rf "$stage"
    exit "$status"
}
trap cleanup EXIT
case "$source" in
    *.zip) /usr/bin/ditto -x -k --norsrc --noextattr "$source" "$stage" ;;
    *.app) /usr/bin/ditto --norsrc --noextattr "$source" "$stage/StreamAgent.app" ;;
    *) printf 'Choose a StreamAgent ZIP archive or .app bundle.\n' >&2; exit 2 ;;
esac
"$root/scripts/verify.sh" "$stage/StreamAgent.app"
/bin/mkdir -p "$HOME/Applications"
install_dir="$(cd "$HOME/Applications" && pwd -P)"
# Resolve symlinks so ~/Applications cannot silently redirect into Documents.
case "$install_dir/" in
    "$HOME/Documents/"*|"$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*)
        printf 'Install location must be outside synced Documents/CloudStorage: %s\n' "$install_dir" >&2; exit 1 ;;
esac
destination="$install_dir/StreamAgent.app"
handoff="$(/usr/bin/mktemp -d "$install_dir/.StreamAgent-install.XXXXXX")"
/usr/bin/ditto --norsrc --noextattr "$stage/StreamAgent.app" "$handoff/StreamAgent.app"
"$root/scripts/verify.sh" "$handoff/StreamAgent.app"
refuse_running
if [ -e "$destination" ] || [ -L "$destination" ]; then
    backup_dir="$install_dir/StreamAgent Backups"
    /bin/mkdir -p "$backup_dir"
    backup="$backup_dir/StreamAgent-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$(/usr/bin/uuidgen).app"
    /bin/mv "$destination" "$backup"
    old_moved=true
fi
/bin/mv "$handoff/StreamAgent.app" "$destination"
new_moved=true
"$root/scripts/verify.sh" "$destination"
if [ "$old_moved" = true ]; then printf 'Previous app preserved at: %s\n' "$backup"; fi
printf 'Installed and verified: %s\n' "$destination"
printf 'No GUI was launched. User configuration was not changed.\n'
