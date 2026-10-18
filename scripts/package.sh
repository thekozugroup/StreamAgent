#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release --product StreamAgent
bin_dir="$(swift build -c release --show-bin-path)"
stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/streamagent-package.XXXXXX")"
trap '/bin/rm -rf "$stage"' EXIT
app="$stage/StreamAgent.app"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/ditto --norsrc --noextattr "$bin_dir/StreamAgent" "$app/Contents/MacOS/StreamAgent"
/usr/bin/ditto --norsrc --noextattr "$root/Resources/Info.plist" "$app/Contents/Info.plist"
xcrun swift "$root/scripts/generate-icon.swift" "$stage/StreamAgent.iconset"
/usr/bin/iconutil -c icns "$stage/StreamAgent.iconset" -o "$app/Contents/Resources/StreamAgent.icns"
# Only this newly generated local staging bundle is stripped of attributes.
/usr/bin/xattr -cr "$app"
/usr/bin/codesign --force --sign - --timestamp=none "$app"
"$root/scripts/verify.sh" "$app"
# Archive BEFORE entering the FileProvider-managed workspace. ZIP bytes retain
# the clean signed bundle even if Finder later adds attributes to dist/*.app.
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$app" "$stage/StreamAgent-macOS.zip"
(cd "$stage" && /usr/bin/shasum -a 256 StreamAgent-macOS.zip > StreamAgent-macOS.zip.sha256)
"$root/scripts/verify.sh" "$stage/StreamAgent-macOS.zip"
/bin/mkdir -p "$root/dist"
/bin/cp "$stage/StreamAgent-macOS.zip" "$root/dist/.StreamAgent-macOS.zip.pending"
/bin/mv -f "$root/dist/.StreamAgent-macOS.zip.pending" "$root/dist/StreamAgent-macOS.zip"
/bin/cp "$stage/StreamAgent-macOS.zip.sha256" "$root/dist/StreamAgent-macOS.zip.sha256"
# The loose bundle is a convenience preview, not the immutable deliverable.
if [ -e "$root/dist/StreamAgent.app" ]; then /bin/mv "$root/dist/StreamAgent.app" "$stage/previous-dist.app"; fi
/usr/bin/ditto --norsrc --noextattr "$app" "$root/dist/StreamAgent.app"
"$root/scripts/verify.sh" "$root/dist/StreamAgent-macOS.zip"
printf 'Deliverable: %s\n' "$root/dist/StreamAgent-macOS.zip"
