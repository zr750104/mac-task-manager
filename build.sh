#!/bin/bash
# タスクマネージャーをビルドして .app バンドルを作る。
#   ./build.sh            → build/MacTaskManager.app を生成
#   ./build.sh --install  → さらに /Applications へコピーしてウィジェットを登録
#   ./build.sh --run      → 生成後に起動
#
# ファイル名はローマ字にしている（Finder やメニューでの表示名は「タスクマネージャー」）。
# 日本語のファイル名だと、濁点の表記の揺れ（「ジ」が「シ」＋濁点に分かれる）で
# システムがウィジェット拡張を引けず、起動を拒否されるため。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="MacTaskManager"
# 以前の版が使っていた日本語のファイル名。見つけたら片付ける。
LEGACY_APP_NAME="タスクマネージャー"
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
# Finder・Dock での表示名（ファイル名はローマ字でも「タスクマネージャー」と出す）
cp -R "$ROOT/Resources/ja.lproj" "$ROOT/Resources/en.lproj" "$BUNDLE/Contents/Resources/"

echo "==> アイコンを生成中"
ICON_TMP="$(mktemp -d)"
if swift "$ROOT/Tools/makeicon.swift" "$ICON_TMP" >/dev/null 2>&1 \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "    アイコンを埋め込みました"
else
  echo "    アイコン生成をスキップしました（アプリの動作には影響しません）"
fi
rm -rf "$ICON_TMP"

# ビルド番号（CFBundleVersion）をビルドのたびに上げる。
# ウィジェットを管理する chronod は、番号が同じだと「前と同じ拡張」とみなして
# 読み直さないため、作り直しても古い状態のまま使い回されてしまう。
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"

# 署名に使う証明書。
# macOS のウィジェットは開発用証明書で署名しないと起動を許可されない。
# Xcode に Apple ID を登録すると "Apple Development: ..." の証明書ができるので、
# 見つかればそれを使い（複数あれば有効期限が最も遅いもの）、無ければ ad-hoc 署名にする。
# SIGN_IDENTITY を指定すればそちらを優先する。
find_development_identity() {
  local best_hash="" best_end=0 hash pem end
  for hash in $(security find-identity -v -p codesigning 2>/dev/null \
                  | awk '/"Apple Development/ {print $2}' | sort -u); do
    pem="$(security find-certificate -a -Z -p 2>/dev/null \
             | awk -v h="$hash" '/^SHA-1 hash:/ {f = ($3 == h)} f' \
             | sed -n '/BEGIN CERT/,/END CERT/p')"
    [ -z "$pem" ] && continue
    end="$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    end="$(date -j -f '%b %e %H:%M:%S %Y %Z' "$end" +%s 2>/dev/null || echo 0)"
    if [ "$end" -gt "$best_end" ]; then best_end="$end"; best_hash="$hash"; fi
  done
  echo "$best_hash"
}
SIGN_ID="${SIGN_IDENTITY:-$(find_development_identity)}"
SIGN_ID="${SIGN_ID:--}"

# --- ウィジェット拡張 ---
# SwiftPM は .appex を作れないため、swiftc で直接ビルドして組み込む。
# 起動の入口は Foundation の _NSExtensionMain にする（Xcode が自動で付ける設定）。
# これがシステムから渡される起動引数を読み取ってからウィジェット本体を呼ぶ。
# 付けないと起動直後に ExtensionFoundation の中で停止する。
echo "==> ウィジェット拡張をビルド中"
APPEX="$BUNDLE/Contents/PlugIns/MacTaskManagerWidget.appex"
WIDGET_OUT="$ROOT/build/widget"
rm -rf "$WIDGET_OUT" "$APPEX"
mkdir -p "$WIDGET_OUT"
if swiftc -O -parse-as-library -application-extension \
     -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" \
     -module-name MacTaskManagerWidget \
     -Xlinker -e -Xlinker _NSExtensionMain \
     "$ROOT"/Widget/*.swift -o "$WIDGET_OUT/MacTaskManagerWidget" >/dev/null 2>&1; then
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$WIDGET_OUT/MacTaskManagerWidget" "$APPEX/Contents/MacOS/"
  cp "$ROOT/Resources/Widget/Info.plist" "$APPEX/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX/Contents/Info.plist"
  # ウィジェットは App Sandbox の権限を付けて、アプリ本体より先に署名する。
  codesign --force --sign "$SIGN_ID" --timestamp=none \
    --entitlements "$ROOT/Resources/Widget/Widget.entitlements" "$APPEX" >/dev/null 2>&1 \
    && echo "    組み込みました" || echo "    ウィジェットの署名に失敗しました"
else
  echo "    ウィジェットのビルドに失敗しました（アプリ本体は作成します）"
fi

# 署名が無いと macOS が起動を拒むことがあるため署名する。
# --deep は付けない。付けるとウィジェットの権限が外れて署名し直されてしまう。
if [ "$SIGN_ID" = "-" ]; then
  echo "==> 署名（ad-hoc）"
  echo "    ※ 開発用証明書が無いため、ウィジェットは表示されません（アプリ本体は動きます）"
else
  echo "==> 署名（開発用証明書 ${SIGN_ID:0:8}…）"
fi
# 別の Mac から持ち込んだ場合に付く隔離属性を外してから署名する。
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
codesign --force --sign "$SIGN_ID" --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
  && echo "    署名しました" || echo "    署名に失敗しました（起動時に警告が出る可能性があります）"

echo "==> 完成: $BUNDLE"

for arg in "$@"; do
  case "$arg" in
    --install)
      echo "==> /Applications へインストール中"
      LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
      # 以前の日本語ファイル名の版が残っていると、同じ ID のアプリが 2 つになり
      # システムがどちらの拡張か迷うので片付ける。
      if [ -d "/Applications/$LEGACY_APP_NAME.app" ]; then
        "$LSREG" -u "/Applications/$LEGACY_APP_NAME.app" 2>/dev/null || true
        rm -rf "/Applications/$LEGACY_APP_NAME.app"
        echo "    以前の「$LEGACY_APP_NAME.app」を削除しました"
      fi
      rm -rf "/Applications/$APP_NAME.app"
      cp -R "$BUNDLE" "/Applications/$APP_NAME.app"
      # build/ の作業用コピーは登録から外し、/Applications の本体だけを登録する。
      "$LSREG" -u "$BUNDLE" 2>/dev/null || true
      "$LSREG" -f -R "/Applications/$APP_NAME.app"
      pluginkit -a "/Applications/$APP_NAME.app/Contents/PlugIns/MacTaskManagerWidget.appex" 2>/dev/null || true
      echo "    /Applications/$APP_NAME.app"
      ;;
    --run)
      echo "==> 起動中"
      open "$BUNDLE"
      ;;
  esac
done
