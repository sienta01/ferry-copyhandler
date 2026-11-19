#!/bin/bash
# Builds Ferry.app with the Command Line Tools alone (no Xcode project needed).
#
#   scripts/build.sh            build into $BUILD_DIR (default: ~/Library/Caches/FerryBuild/Ferry.app)
#   scripts/build.sh install    build, copy to /Applications (or ~/Applications), register, enable
#                               the Finder extension and open Ferry
#
# Environment:
#   ARCHS="arm64 x86_64"   universal build (default: this Mac's architecture)
#   SIGN_IDENTITY="…"      a codesigning identity; default "-" (ad-hoc, fine for your own Mac)
#   BUNDLE_ID="…"          default local.ferry.Ferry
#
# The build happens outside the repository so cloud-synced folders don't churn on build products.
set -euo pipefail

APP_NAME="Ferry"
VERSION="1.0.0"
BUNDLE_ID="${BUNDLE_ID:-local.ferry.Ferry}"
MIN_MACOS="13.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/FerryBuild}"
ARCHS="${ARCHS:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SDK="$(xcrun --show-sdk-path)"
APP="$BUILD_DIR/$APP_NAME.app"
EXT="$APP/Contents/PlugIns/FerryFinderSync.appex"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p "$BUILD_DIR"

# Per-machine secret shared by the app and its Finder extension, so only the extension can drive
# the ferry:// URL scheme (see Sources/Ferry/Integration/IPCRequest.swift).
TOKEN_FILE="$BUILD_DIR/ipc-token"
[ -s "$TOKEN_FILE" ] || openssl rand -hex 24 > "$TOKEN_FILE"
TOKEN="$(cat "$TOKEN_FILE")"

APP_BINS=()
CLI_BINS=()
EXT_BINS=()
for arch in $ARCHS; do
  triple="$arch-apple-macosx$MIN_MACOS"
  echo "==> Building Ferry and ferry-cli for $arch"
  swift build -c release --package-path "$ROOT" --scratch-path "$BUILD_DIR/spm" --triple "$triple" \
    --product Ferry 2>&1 | grep -v "search path" || true
  swift build -c release --package-path "$ROOT" --scratch-path "$BUILD_DIR/spm" --triple "$triple" \
    --product ferry-cli 2>&1 | grep -v "search path" || true
  bin="$(swift build -c release --package-path "$ROOT" --scratch-path "$BUILD_DIR/spm" --triple "$triple" --show-bin-path)"
  [ -x "$bin/Ferry" ] && [ -x "$bin/ferry-cli" ] || { echo "Build failed for $arch" >&2; exit 1; }
  # Newer SwiftPM puts every triple in the same Products folder, so stash each arch's output.
  mkdir -p "$BUILD_DIR/bin-$arch"
  cp "$bin/Ferry" "$bin/ferry-cli" "$BUILD_DIR/bin-$arch/"
  APP_BINS+=("$BUILD_DIR/bin-$arch/Ferry")
  CLI_BINS+=("$BUILD_DIR/bin-$arch/ferry-cli")

  echo "==> Building the Finder extension for $arch"
  out="$BUILD_DIR/FerryFinderSync-$arch"
  swiftc -O -whole-module-optimization -module-name FerryFinderSync \
    -target "$arch-apple-macos$MIN_MACOS" -sdk "$SDK" \
    -application-extension -parse-as-library \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework FinderSync -framework AppKit \
    "$ROOT/FinderExtension/FinderSync.swift" "$ROOT/Sources/Ferry/Integration/IPCRequest.swift" \
    -o "$out"
  EXT_BINS+=("$out")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
lipo -create "${APP_BINS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
lipo -create "${CLI_BINS[@]}" -output "$APP/Contents/MacOS/ferry-cli"
lipo -create "${EXT_BINS[@]}" -output "$EXT/Contents/MacOS/FerryFinderSync"

fill() {
  sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" \
      -e "s/__BUILD__/$BUILD_NUMBER/g" -e "s/__TOKEN__/$TOKEN/g" "$1" > "$2"
  plutil -lint -s "$2"
}
fill "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
fill "$ROOT/Resources/FinderSync-Info.plist" "$EXT/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
printf 'XPC!????' > "$EXT/Contents/PkgInfo"

echo "==> Signing (identity: $SIGN_IDENTITY)"
SIGN_OPTS=()
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_OPTS=(--options runtime --timestamp); fi
# Inside out: extension, helper tool, then the app.
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} \
  --entitlements "$ROOT/Resources/FinderSync.entitlements" "$EXT"
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} "$APP/Contents/MacOS/ferry-cli"
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} \
  --entitlements "$ROOT/Resources/Ferry.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

du -sh "$APP" | awk '{print "==> Built " $2 " (" $1 ")"}'

if [ "${1:-}" = "install" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  TARGET="$DEST/$APP_NAME.app"
  echo "==> Installing to $TARGET"
  if pgrep -xq "$APP_NAME"; then
    # Asks Ferry to quit; if a transfer is running, Ferry asks first and you can say no.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -xq "$APP_NAME" || break; sleep 0.5; done
    if pgrep -xq "$APP_NAME"; then
      echo "Ferry is still running (a transfer may be in progress), so it was left alone." >&2
      echo "Run 'scripts/build.sh install' again once it's finished." >&2
      exit 1
    fi
  fi
  rm -rf "$TARGET"
  ditto "$APP" "$TARGET"
  # Keep LaunchServices and pluginkit pointed at the installed copy only.
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  pluginkit -r "$EXT" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$TARGET"
  pluginkit -a "$TARGET/Contents/PlugIns/FerryFinderSync.appex"
  pluginkit -e use -i "$BUNDLE_ID.FinderSync"
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true  # refresh the Services menu
  open "$TARGET"
  echo "==> Done. If the Finder menu items don't show yet, relaunch Finder (⌥-right-click Finder in the Dock ▸ Relaunch)."
fi
