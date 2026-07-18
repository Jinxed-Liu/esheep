#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
developer_dir="/Volumes/Mac os - Data/Applications/Xcode-beta.app/Contents/Developer"

python3 "$repo_root/tools/check_product_emoji.py" "$repo_root/eSheepNext" "$repo_root/eSheepNextTests"
DEVELOPER_DIR="$developer_dir" xcodebuild build-for-testing \
  -project "$repo_root/eSheepNext.xcodeproj" \
  -scheme eSheepNext \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/eSheepNextTestDerived \
  CODE_SIGNING_ALLOWED=NO
