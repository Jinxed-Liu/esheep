#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"

usage() {
  cat <<'USAGE'
用法：./tools/verify_local.sh [static|ios|web|backend|db|all] [...]

  static   静态检查、本地化、Privacy Manifest 与公开配置检查
  ios      Debug/Staging/Release 无签名构建与完整 XCTest
  web      Web 测试、Sites 产物验证、构建与 npm audit
  backend  CloudBase 网关与遗留身份 Worker 的检查、测试与 npm audit
  db       仅对本地 Supabase 容器执行 reset、pgTAP、lint 与 advisors
  all      依次执行以上全部门禁（默认）

可一次传入多个入口，例如：./tools/verify_local.sh static web backend
非 CI 环境运行 db/all 前必须显式设置 ALLOW_LOCAL_DB_RESET=1。
USAGE
}

section() {
  print -r -- ""
  print -r -- "==> $1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 -- "缺少验证依赖：$1"
    return 1
  fi
}

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

require_stable_xcode() {
  local developer_dir="$1"
  if [[ "$developer_dir" == *"Xcode-beta.app"* && "${ALLOW_BETA_XCODE:-0}" != "1" ]]; then
    print -u2 -- "发布门禁禁止 Beta Xcode。安装稳定版 Xcode，或仅做诊断时显式设置 ALLOW_BETA_XCODE=1。"
    return 1
  fi
}

lint_plist() {
  local plist_path="$1"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist_path"
    return
  fi

  python3 - "$plist_path" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as plist_file:
    plistlib.load(plist_file)
print(f"{sys.argv[1]}: OK")
PY
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
  if rg -qi 'service[_-]?role|SUPABASE_SERVICE_ROLE_KEY|BEGIN PRIVATE KEY' "$config"; then
    print -u2 -- "${environment} iOS 配置包含禁止的服务端 Secret。"
    return 1
  fi
}

run_node_test_with_discovery_gate() {
  local directory="$1"
  local output_file
  output_file="$(mktemp -t esheep-node-test.XXXXXX)"
  (cd "$directory" && npm test) 2>&1 | tee "$output_file"
  if ! rg -q '^# tests [1-9][0-9]*$' "$output_file"; then
    print -u2 -- "无法证明 Node 测试实际发现并执行：$directory"
    return 1
  fi
  if rg -q '^# (fail|cancelled) [1-9][0-9]*$' "$output_file"; then
    print -u2 -- "Node 测试存在失败或取消：$directory"
    return 1
  fi
}

run_vitest_with_discovery_gate() {
  local directory="$1"
  local output_file
  output_file="$(mktemp -t esheep-vitest.XXXXXX)"
  (cd "$directory" && npm test) 2>&1 | tee "$output_file"
  if rg -q 'Test Files[[:space:]]+no tests|No test files found' "$output_file"; then
    print -u2 -- "Vitest 测试发现数为 0：$directory"
    return 1
  fi
  if ! rg -q 'Test Files[[:space:]]+[1-9][0-9]* passed|[1-9][0-9]* passing' "$output_file"; then
    print -u2 -- "无法证明 Vitest 测试实际执行并通过：$directory"
    return 1
  fi
}

run_worker_vitest_from_ascii_copy() {
  local source_directory="$1"
  local staged_directory
  staged_directory="$(mktemp -d /tmp/esheep-worker.XXXXXX)"
  rsync -a --exclude node_modules "$source_directory/" "$staged_directory/"
  (cd "$staged_directory" && npm ci --ignore-scripts)
  run_vitest_with_discovery_gate "$staged_directory"
}

verify_static() {
  section "static：静态、隐私与配置门禁"
  require_command git
  require_command python3
  require_command rg

  (cd "$repo_root" && git diff --check && git diff --cached --check)
  python3 "$repo_root/tools/check_product_emoji.py" "$repo_root/eSheepNext" "$repo_root/eSheepNextTests"
  python3 "$repo_root/tools/check_localizations.py"
  lint_plist "$repo_root/eSheepNext/PrivacyInfo.xcprivacy"
  lint_plist "$repo_root/eSheepNextWidget/PrivacyInfo.xcprivacy"

  if [[ "${VERIFY_PUBLIC_CONFIG:-1}" == "1" ]]; then
    verify_supabase_public_config Staging
    verify_supabase_public_config Release
  else
    print -r -- "CI 未注入本地公开配置，跳过 *.local.xcconfig 值校验。"
  fi

  if [[ "${VERIFY_ALLOW_LEGAL_PLACEHOLDERS:-0}" == "1" ]]; then
    zsh "$repo_root/tools/verify_privacy_compliance.sh" --allow-placeholders
  else
    zsh "$repo_root/tools/verify_privacy_compliance.sh"
  fi
}

verify_ios() {
  section "ios：三配置构建与完整 XCTest"
  require_command python3
  local developer_dir
  developer_dir="$(resolve_developer_dir)"
  require_stable_xcode "$developer_dir"

  local local_derived_data
  local_derived_data="$(mktemp -d -t esheep-derived.XXXXXX)"
  local configuration settings_file resolved_supabase_url
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
        return 1
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

  local test_destination="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro}"
  local test_result="$local_derived_data/TestResults.xcresult"
  local test_derived_data="$local_derived_data/Tests"
  DEVELOPER_DIR="$developer_dir" xcodebuild build-for-testing \
    -project "$repo_root/eSheepNext.xcodeproj" \
    -scheme eSheepNext \
    -configuration Debug \
    -destination "$test_destination" \
    -derivedDataPath "$test_derived_data" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    COMPILER_INDEX_STORE_ENABLE=NO

  DEVELOPER_DIR="$developer_dir" xcodebuild test-without-building \
    -project "$repo_root/eSheepNext.xcodeproj" \
    -scheme eSheepNext \
    -configuration Debug \
    -destination "$test_destination" \
    -derivedDataPath "$test_derived_data" \
    -resultBundlePath "$test_result" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    COMPILER_INDEX_STORE_ENABLE=NO

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
}

verify_web() {
  section "web：测试、Sites 构建与依赖审计"
  require_command npm
  (cd "$repo_root/web" && npm run build)
  run_node_test_with_discovery_gate "$repo_root/web"
  (cd "$repo_root/web" && npm run test:sites && npm audit)
}

verify_backend() {
  section "backend：CloudBase 网关与遗留身份 Worker"
  require_command npm
  require_command rg
  require_command rsync

  (cd "$repo_root/backend/identity-worker" && npm run check && npm audit)
  run_worker_vitest_from_ascii_copy "$repo_root/backend/identity-worker"

  (cd "$repo_root/backend/cloudbase-identity-gateway" && npm run check)
  run_node_test_with_discovery_gate "$repo_root/backend/cloudbase-identity-gateway"
  (cd "$repo_root/backend/cloudbase-identity-gateway" && npm run security:audit)
}

verify_db() {
  section "db：一次性本地 Supabase migration、pgTAP、lint 与 advisors"
  require_command supabase
  require_command docker
  require_command rg

  if [[ "${CI:-false}" != "true" && "${ALLOW_LOCAL_DB_RESET:-0}" != "1" ]]; then
    print -u2 -- "db 门禁会重置本地 Supabase 数据。确认它是一次性环境后，设置 ALLOW_LOCAL_DB_RESET=1 重试。"
    return 1
  fi

  docker info >/dev/null

  local project_id
  project_id="$(awk -F '"' '/^project_id = / { print $2; exit }' "$repo_root/supabase/config.toml")"
  if [[ -z "$project_id" ]] || ! print -r -- "$project_id" | rg -q '^[A-Za-z0-9_-]+$'; then
    print -u2 -- "supabase/config.toml 的 project_id 缺失或不安全。"
    return 1
  fi

  local db_container="supabase_db_${project_id}"
  if ! docker ps --format '{{.Names}}' | rg -qx "$db_container"; then
    (cd "$repo_root" && supabase start)
  fi

  # 以下命令全部明确绑定 --local；此入口不得添加 link、push 或远端凭据。
  (cd "$repo_root" && supabase db reset --local)
  "$repo_root/tools/run_supabase_pgtap.sh"
  (cd "$repo_root" && supabase db lint --local && supabase db advisors --local)
}

typeset -a requested_modes
if (( $# == 0 )); then
  requested_modes=(all)
else
  requested_modes=("$@")
fi

typeset -A seen_modes
run_mode() {
  local mode="$1"
  if [[ -n "${seen_modes[$mode]-}" ]]; then
    return
  fi
  seen_modes[$mode]=1

  case "$mode" in
    static) verify_static ;;
    ios) verify_ios ;;
    web) verify_web ;;
    backend) verify_backend ;;
    db) verify_db ;;
    help|-h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -- "未知验证入口：$mode"
      usage >&2
      return 2
      ;;
  esac
}

for requested_mode in "${requested_modes[@]}"; do
  if [[ "$requested_mode" == "all" ]]; then
    for expanded_mode in static ios web backend db; do
      run_mode "$expanded_mode"
    done
  else
    run_mode "$requested_mode"
  fi
done

print -r -- ""
print -r -- "验证入口通过：${requested_modes[*]}"
