#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"

resolve_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    print -r -- "$DEVELOPER_DIR"
    return
  fi

  local selected
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ -x "$selected/usr/bin/xcodebuild" ]]; then
    print -r -- "$selected"
    return
  fi

  local candidate
  for candidate in \
    "/Applications/Xcode.app/Contents/Developer" \
    "/Applications/Xcode-beta.app/Contents/Developer" \
    "/Volumes/Mac os/Applications/Xcode.app/Contents/Developer" \
    "/Volumes/Mac os/Applications/Xcode-beta.app/Contents/Developer" \
    "/Volumes/Mac os - Data/Applications/Xcode.app/Contents/Developer" \
    "/Volumes/Mac os - Data/Applications/Xcode-beta.app/Contents/Developer"; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      print -r -- "$candidate"
      return
    fi
  done

  print -u2 -- "未找到可用的完整 Xcode。请设置 DEVELOPER_DIR 后重试。"
  return 1
}

developer_dir="$(resolve_developer_dir)"

python3 "$repo_root/tools/check_product_emoji.py" "$repo_root/eSheepNext" "$repo_root/eSheepNextTests"
DEVELOPER_DIR="$developer_dir" xcodebuild build-for-testing \
  -project "$repo_root/eSheepNext.xcodeproj" \
  -scheme eSheepNext \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/eSheepNextTestDerived \
  CODE_SIGNING_ALLOWED=NO

(cd "$repo_root/backend/identity-worker" && npm test)
(cd "$repo_root/backend/cloudbase-identity-gateway" && npm run check && npm test && npm run security:audit)
