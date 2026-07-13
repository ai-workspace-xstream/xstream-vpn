#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APK_PATH="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
BRANCH="${BRANCH:-$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)}"
BUILD_ID="${BUILD_ID:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
BUILD_DATE="${BUILD_DATE:-$(date '+%Y-%m-%d')}"
UNAME_S="${UNAME_S:-$(uname -s)}"
FLUTTER_BIN="${FLUTTER:-flutter}"

normalize_exec_path() {
  local value="${1:-}"
  if [[ -z "$value" || "$value" == "flutter" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if command -v cygpath >/dev/null 2>&1 && [[ "$value" =~ ^[A-Za-z]:[\\/].* ]]; then
    cygpath -u "$value"
    return 0
  fi

  printf '%s' "$value"
}

FLUTTER_BIN="$(normalize_exec_path "$FLUTTER_BIN")"

case "$UNAME_S" in
  Darwin|Linux|MINGW*|MSYS*|CYGWIN*|Windows_NT)
    ;;
  *)
    echo "Android APK build is only supported on macOS, Linux, or Windows"
    exit 0
    ;;
esac

if [[ -n "$FLUTTER_BIN" ]] && [[ "$FLUTTER_BIN" != "flutter" ]] && [[ ! -e "$FLUTTER_BIN" ]]; then
  echo "Flutter executable not found: $FLUTTER_BIN"
  exit 0
fi

cd "$ROOT_DIR"

echo ">>> Building Android native bridge (.so) ..."
./build_scripts/build_android_xray.sh

echo ">>> Building Android release APK ..."
"$FLUTTER_BIN" build apk --release \
  --dart-define=BRANCH_NAME="$BRANCH" \
  --dart-define=BUILD_ID="$BUILD_ID" \
  --dart-define=BUILD_DATE="$BUILD_DATE"

if [[ ! -f "$APK_PATH" ]]; then
  echo "APK build completed but output not found: $APK_PATH"
  exit 1
fi

echo ">>> APK ready:"
echo "    $APK_PATH"
