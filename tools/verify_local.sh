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

if [[ "$developer_dir" == *"Xcode-beta.app"* && "${ALLOW_BETA_XCODE:-0}" != "1" ]]; then
  print -u2 -- "发布门禁禁止 Beta Xcode。安装正式版 Xcode 26/27，或仅做非发布诊断时显式设置 ALLOW_BETA_XCODE=1。"
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 -- "缺少发布门禁依赖：$1"
    return 1
  fi
}

run_vitest_with_discovery_gate() {
  local directory="$1"
  local output_file
  output_file="$(mktemp -t esheep-vitest.XXXXXX)"
  (cd "$directory" && npm test) 2>&1 | tee "$output_file"
  if rg -q 'Test Files[[:space:]]+no tests|No test files found' "$output_file"; then
    print -u2 -- "测试发现数为 0：$directory"
    return 1
  fi
  if ! rg -q 'Test Files[[:space:]]+[1-9][0-9]* passed|[1-9][0-9]* passing' "$output_file"; then
    print -u2 -- "无法证明测试实际执行并通过：$directory"
    return 1
  fi
}

verify_supabase_public_config() {
  local environment="$1"
  local config="$repo_root/Config/${environment}Environment.local.xcconfig"
  if [[ ! -f "$config" ]]; then
    print -u2 -- "缺少 ${environment} Supabase 公开配置：$config"
    return 1
  fi
  if ! rg -q '^SUPABASE_URL[[:space:]]*=[[:space:]]*https:' "$config"; then
    print -u2 -- "${environment} SUPABASE_URL 缺失或无效。"
    return 1
  fi
  if ! rg -q '^SUPABASE_PUBLISHABLE_KEY[[:space:]]*=[[:space:]]*sb_publishable_[A-Za-z0-9_-]+[[:space:]]*$' "$config"; then
    print -u2 -- "${environment} publishable key 缺失或无效。"
    return 1
  fi
  if rg -q 'service[_-]?role|SUPABASE_SERVICE_ROLE_KEY|BEGIN PRIVATE KEY' "$config"; then
    print -u2 -- "${environment} iOS 配置包含禁止的服务端 Secret。"
    return 1
  fi
}

python3 "$repo_root/tools/check_product_emoji.py" "$repo_root/eSheepNext" "$repo_root/eSheepNextTests"
python3 "$repo_root/tools/check_localizations.py"
plutil -lint "$repo_root/eSheepNext/PrivacyInfo.xcprivacy"
plutil -lint "$repo_root/eSheepNextWidget/PrivacyInfo.xcprivacy"
verify_supabase_public_config Staging
verify_supabase_public_config Release
if rg -q '\{\{(DOMAIN|LEGAL_ENTITY)\}\}' "$repo_root/release"; then
  print -u2 -- "公开网站或 App Store 元数据仍含域名/法律主体占位符。"
  exit 1
fi

local_derived_data="$(mktemp -d -t esheep-derived.XXXXXX)"
for configuration in Debug Staging Release; do
  settings_file="$(mktemp -t esheep-${configuration:l}-settings.XXXXXX)"
  DEVELOPER_DIR="$developer_dir" xcodebuild -showBuildSettings \
    -project "$repo_root/eSheepNext.xcodeproj" \
    -scheme eSheepNext \
    -configuration "$configuration" > "$settings_file"
  if [[ "$configuration" != "Debug" ]]; then
    resolved_supabase_url="$(awk -F ' = ' '/^[[:space:]]*SUPABASE_URL = / { print $2; exit }' "$settings_file")"
    if [[ "$resolved_supabase_url" != https://*.* ]]; then
      print -u2 -- "${configuration} 构建解析后的 SUPABASE_URL 无效：$resolved_supabase_url"
      exit 1
    fi
  fi
  DEVELOPER_DIR="$developer_dir" xcodebuild build \
    -project "$repo_root/eSheepNext.xcodeproj" \
    -scheme eSheepNext \
    -configuration "$configuration" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$local_derived_data/$configuration" \
    CODE_SIGNING_ALLOWED=NO
done

test_destination="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro}"
test_result="$local_derived_data/TestResults.xcresult"
DEVELOPER_DIR="$developer_dir" xcodebuild test \
  -project "$repo_root/eSheepNext.xcodeproj" \
  -scheme eSheepNext \
  -configuration Release \
  -destination "$test_destination" \
  -derivedDataPath "$local_derived_data/Tests" \
  -resultBundlePath "$test_result" \
  ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR="$developer_dir" xcrun xcresulttool get test-results summary \
  --path "$test_result" --compact | python3 -c '
import json, sys
summary = json.load(sys.stdin)
total = int(summary.get("totalTestCount", 0))
failed = int(summary.get("failedTests", 0))
skipped = int(summary.get("skippedTests", 0))
if total <= 0 or failed != 0 or skipped != 0:
    raise SystemExit(
        f"XCTest gate failed: discovered={total}, failed={failed}, skipped={skipped}"
    )
print(f"XCTest gate passed: discovered={total}, failed=0, skipped=0")
'

require_command supabase
require_command docker
docker info >/dev/null
(cd "$repo_root" && supabase db reset && supabase test db)

# Legacy protocol regressions. These are not 3.1 production authority gates,
# but if run they must execute at least one real test.
run_vitest_with_discovery_gate "$repo_root/backend/identity-worker"
(cd "$repo_root/backend/cloudbase-identity-gateway" && npm run check && npm test && npm run security:audit)
