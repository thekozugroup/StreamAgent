#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="${1:-$root/dist/StreamAgent-macOS.zip}"
source="${source%/}"
stage=""
cleanup() { if [ -n "$stage" ]; then /bin/rm -rf "$stage"; fi; }
trap cleanup EXIT
case "$source" in
    *.zip)
        test -f "$source"
        source="$(cd "$(dirname "$source")" && pwd -P)/$(basename "$source")"
        if [ -f "$source.sha256" ]; then
            expected="$(/usr/bin/awk 'NR == 1 {print $1}' "$source.sha256")"
            actual="$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')"
            if [ "$actual" != "$expected" ]; then printf 'Archive checksum mismatch: %s\n' "$source" >&2; exit 1; fi
        fi
        stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/streamagent-verify.XXXXXX")"
        /usr/bin/ditto -x -k --norsrc --noextattr "$source" "$stage"
        app="$stage/StreamAgent.app"
        ;;
    *.app)
        app="$(cd "$(dirname "$source")" && pwd -P)/$(basename "$source")"
        ;;
    *) printf 'Usage: %s [StreamAgent-macOS.zip | /path/StreamAgent.app]\n' "$0" >&2; exit 2 ;;
esac
executable="$app/Contents/MacOS/StreamAgent"
test -x "$executable"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app"
links="$(/usr/bin/otool -L "$executable")"
if ! printf '%s\n' "$links" | /usr/bin/awk 'NR > 1 && $1 !~ /^\/System\/Library\// && $1 !~ /^\/usr\/lib\// { print $1; bad=1 } END { exit bad }'; then
    printf 'Unexpected external dynamic dependency\n' >&2
    exit 1
fi
if [ -n "$(/usr/bin/find "$app/Contents" -type f \( -name '*.dylib' -o -name '*.so' \))" ]; then
    printf 'Unexpected embedded dynamic dependency\n' >&2
    exit 1
fi
result="$("$executable" --smoke-test)"
printf '%s\n' "$result"
printf '%s\n' "$result" | /usr/bin/plutil -extract success raw -o - - | /usr/bin/awk '$0 != "true" { exit 1 }' >/dev/null
if [ -n "$stage" ]; then printf 'Verified archive: %s\n' "$source"; else printf 'Verified installed/app path: %s\n' "$app"; fi
printf 'Signature, system-only links, and non-GUI smoke check passed.\n'
