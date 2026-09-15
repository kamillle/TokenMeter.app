#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$ROOT/TokenMeter.app"
INSTALL_DIR="${TOKENMETER_INSTALL_DIR:-/Applications}"
DESTINATION="$INSTALL_DIR/TokenMeter.app"

echo "TokenMeterをビルドしています..."
bash "$ROOT/build.sh"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "インストール先がありません: $INSTALL_DIR" >&2
  exit 1
fi
if [[ ! -w "$INSTALL_DIR" ]]; then
  echo "インストール先へ書き込めません: $INSTALL_DIR" >&2
  echo "FinderでTokenMeter.appをApplicationsへ移すか、書き込み可能なTOKENMETER_INSTALL_DIRを指定してください。" >&2
  exit 1
fi

echo "起動中のTokenMeterを終了しています..."
/usr/bin/pkill -x TokenMeter 2>/dev/null || true
for _ in {1..50}; do
  if ! /usr/bin/pgrep -x TokenMeter >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.1
done
if /usr/bin/pgrep -x TokenMeter >/dev/null 2>&1; then
  echo "TokenMeterを終了できなかったため、インストールを中止しました。" >&2
  exit 1
fi

echo "$DESTINATION へインストールしています..."
if [[ -e "$DESTINATION" ]]; then
  /bin/rm -rf "$DESTINATION"
fi
/usr/bin/ditto "$SOURCE_APP" "$DESTINATION"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"

echo "TokenMeterを起動しています..."
/usr/bin/open "$DESTINATION"
echo "インストール完了: $DESTINATION"
