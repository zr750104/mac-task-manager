#!/bin/bash
# タスクマネージャーをビルドして .app バンドルを作る。
#   ./build.sh            → build/タスクマネージャー.app を生成
#   ./build.sh --install  → さらに /Applications へコピー
#   ./build.sh --run      → 生成後に起動
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="タスクマネージャー"
BUNDLE="$ROOT/build/$APP_NAME.app"
CONFIG=release

# --- 前提チェック ---------------------------------------------------------
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_MAJOR" -lt 14 ]; then
  echo "エラー: macOS 14 以降が必要です（現在 $(sw_vers -productVersion)）。" >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "エラー: Swift ツールチェーンが見つかりません。" >&2
  echo "  Xcode か、コマンドラインツール（xcode-select --install）を入れてください。" >&2
  exit 1
fi
echo "==> $(sw_vers -productName) $(sw_vers -productVersion) / $(uname -m) / $(sysctl -n machdep.cpu.brand_string)"

echo "==> Swift をビルド中 ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/MacTaskManager"

echo "==> .app バンドルを作成中"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/MacTaskManager"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> アイコンを生成中"
ICON_TMP="$(mktemp -d)"
if swift "$ROOT/Tools/makeicon.swift" "$ICON_TMP" >/dev/null 2>&1 \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "    アイコンを埋め込みました"
else
  echo "    アイコン生成をスキップしました（アプリの動作には影響しません）"
fi
rm -rf "$ICON_TMP"

# 署名が無いと macOS が起動を拒むことがあるため ad-hoc 署名する。
echo "==> ad-hoc 署名"
# 別の Mac から持ち込んだ場合に付く隔離属性を外してから署名する。
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
  && echo "    署名しました" || echo "    署名に失敗しました（起動時に警告が出る可能性があります）"

echo "==> 完成: $BUNDLE"

for arg in "$@"; do
  case "$arg" in
    --install)
      echo "==> /Applications へインストール中"
      rm -rf "/Applications/$APP_NAME.app"
      cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
      echo "    /Applications/$APP_NAME.app"
      ;;
    --run)
      echo "==> 起動中"
      open "$BUNDLE"
      ;;
  esac
done
