#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
allow_placeholders=0
if [[ "${1:-}" == "--allow-placeholders" ]]; then
  allow_placeholders=1
elif [[ $# -gt 0 ]]; then
  print -u2 -- "用法：$0 [--allow-placeholders]"
  exit 2
fi

fail() {
  print -u2 -- "隐私合规门禁失败：$1"
  exit 1
}

expected_version="2026.09.01"
version_source="$repo_root/eSheepNext/Services/LegalConsentStore.swift"
for key in terms privacy crossBorder ai; do
  rg -q "static let ${key} = \"${expected_version}\"" "$version_source" ||
    fail "LegalPolicyVersions.${key} 与 ${expected_version} 不一致。"
done

for policy in "$repo_root"/release/legal/*.md; do
  rg -q "^(版本：|Version: )${expected_version}" "$policy" ||
    fail "法律文本版本不一致：$policy"
done

manifest_dump="$(python3 - "$repo_root/eSheepNext/PrivacyInfo.xcprivacy" <<'PY'
import json
import plistlib
import sys

with open(sys.argv[1], "rb") as manifest_file:
    manifest = plistlib.load(manifest_file)
print(json.dumps(manifest, ensure_ascii=False, sort_keys=True))
PY
)" || fail "Privacy Manifest 不是有效的 plist。"
for data_type in \
  Name EmailAddress PhysicalAddress PreciseLocation PhotosorVideos AudioData \
  OtherUserContent UserID DeviceID OtherUsageData OtherDiagnosticData; do
  if [[ "$manifest_dump" != *"NSPrivacyCollectedDataType${data_type}"* ]]; then
    fail "Privacy Manifest 缺少 NSPrivacyCollectedDataType${data_type}。"
  fi
done
if [[ "$manifest_dump" == *'"NSPrivacyCollectedDataTypeTracking": true'* ]]; then
  fail "Privacy Manifest 不得把数据声明为跨 App/网站跟踪。"
fi

rg -q 'static let defaultRetainsSentAudio = false' \
  "$repo_root/eSheepNext/Services/InsightMediaServices.swift" ||
  fail "AI 语音默认保留必须为关闭。"
rg -q '@State private var hasAcceptedTermsAndPrivacy = false' \
  "$repo_root/eSheepNext/Features/Account/WelcomeView.swift" ||
  fail "服务条款/隐私政策同意必须默认不勾选。"
rg -q '@State private var hasAcceptedCrossBorder = false' \
  "$repo_root/eSheepNext/Features/Account/WelcomeView.swift" ||
  fail "境外云处理同意必须默认不勾选。"
rg -q 'hasCurrentLegalConsent\(for: account\)' \
  "$repo_root/eSheepNext/App/RootView.swift" ||
  fail "缺少旧用户按当前版本重新同意的工作区门禁。"
if rg -q 'accepted(Terms|Privacy)Version = "1\.0"' \
  "$repo_root/eSheepNext/Models/AccountProfile.swift"; then
  fail "AccountProfile 仍会推定用户已同意旧版本。"
fi

migration="$repo_root/supabase/migrations/20260827224500_legal_consent_receipts.sql"
for evidence in \
  legal_consent_receipts record_legal_consent \
  legal_consent_withdrawal_events record_legal_consent_withdrawal \
  ai_privacy_consent_events record_ai_privacy_consent; do
  rg -q "$evidence" "$migration" || fail "Supabase 迁移缺少 $evidence。"
done
rg -q 'force row level security' "$migration" ||
  fail "法律同意证据表没有强制 RLS。"

self_audit="$repo_root/docs/compliance/小型个人信息处理者合规审计自查表.md"
audit_item_count="$(rg -c '^\| [0-9]+ \|' "$self_audit")"
[[ "$audit_item_count" == "24" ]] ||
  fail "官方逐项自查应为 24 项，当前为 ${audit_item_count} 项。"

for questionnaire in \
  "$repo_root/release/app-store/privacy/privacy-questionnaire.zh-Hans.md" \
  "$repo_root/release/app-store/privacy/privacy-questionnaire.en.md"; do
  [[ -f "$questionnaire" ]] || fail "缺少 App Store 隐私问卷：$questionnaire"
done

site_snapshot="$(mktemp -d -t esheep-legal-site.XXXXXX)"
trap 'rm -rf -- "$site_snapshot"' EXIT
cp -R "$repo_root/release/site-template/." "$site_snapshot/"
node "$repo_root/tools/render_legal_site.mjs" >/dev/null
diff -qr "$site_snapshot" "$repo_root/release/site-template" >/dev/null ||
  fail "公开法律网页不是 release/legal 当前内容的幂等生成结果。"

for route in \
  zh-cn/support zh-cn/privacy zh-cn/terms zh-cn/ai-privacy zh-cn/account-deletion \
  en/support en/privacy en/terms en/ai-privacy en/account-deletion; do
  [[ -f "$repo_root/release/site-template/$route/index.html" ]] ||
    fail "缺少公开网站路由：/$route/"
done

for route in privacy terms ai-privacy account-deletion support; do
  rg -q "href=\"\.\./\.\./en/${route}/\"" \
    "$repo_root/release/site-template/zh-cn/$route/index.html" ||
    fail "中文 /${route}/ 的 English 链接没有指向同名英文页面。"
  rg -q "href=\"\.\./\.\./zh-cn/${route}/\"" \
    "$repo_root/release/site-template/en/$route/index.html" ||
    fail "英文 /${route}/ 的简体中文链接没有指向同名中文页面。"
done

placeholder_pattern='\{\{[A-Z0-9_]+\}\}'
placeholder_files="$(
  rg -l "$placeholder_pattern" \
    "$repo_root/release" \
    "$repo_root/docs/compliance" \
    "$repo_root/eSheepNext/Features/Account/LegalDocumentView.swift" || true
)"
if [[ -n "$placeholder_files" ]]; then
  if (( allow_placeholders )); then
    print -r -- "预发布占位符仍存在（正式发布门禁会阻止）："
    print -r -- "$placeholder_files"
  else
    print -u2 -- "下列文件仍含必须由运营者确认的发布占位符："
    print -u2 -- "$placeholder_files"
    exit 1
  fi
fi

print -r -- "隐私合规一致性检查通过（版本 ${expected_version}）。"
