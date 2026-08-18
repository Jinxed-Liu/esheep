#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
expected_xcode_build="${EXPECTED_XCODE_BUILD:-27A5228h}"
release_config="$repo_root/Config/ReleaseEnvironment.local.xcconfig"
test_destination="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
derived_data="${TESTFLIGHT_DERIVED_DATA:-$(mktemp -d -t esheep-testflight.XXXXXX)}"

fail() {
  print -u2 -- "Internal TestFlight gate failed: $1"
  exit 1
}

[[ -x "$developer_dir/usr/bin/xcodebuild" ]] || fail "Xcode developer directory is unavailable: $developer_dir"
xcode_build="$(DEVELOPER_DIR="$developer_dir" xcodebuild -version | awk '/Build version/ { print $3 }')"
[[ "$xcode_build" == "$expected_xcode_build" ]] || fail "expected Xcode build $expected_xcode_build, found $xcode_build"

[[ -f "$release_config" ]] || fail "missing ignored ReleaseEnvironment.local.xcconfig"
rg -q '^SUPABASE_URL[[:space:]]*=[[:space:]]*https:' "$release_config" || fail "Release SUPABASE_URL is missing"
rg -q '^SUPABASE_PUBLISHABLE_KEY[[:space:]]*=[[:space:]]*sb_publishable_[A-Za-z0-9_-]+[[:space:]]*$' "$release_config" || fail "Release publishable key is missing or not a publishable key"
if rg -qi 'service[_-]?role|database[_-]?password|smtp[_-]?password|BEGIN (RSA |EC )?PRIVATE KEY' "$release_config"; then
  fail "Release client configuration contains a server-side secret"
fi

python3 "$repo_root/tools/check_product_emoji.py" "$repo_root/eSheepNext" "$repo_root/eSheepNextTests"
plutil -lint "$repo_root/eSheepNext/PrivacyInfo.xcprivacy"
plutil -lint "$repo_root/eSheepNextWidget/PrivacyInfo.xcprivacy"
(cd "$repo_root" && git diff --check)

settings_file="$(mktemp -t esheep-build-settings.XXXXXX)"
DEVELOPER_DIR="$developer_dir" xcodebuild -showBuildSettings \
  -project "$repo_root/eSheepNext.xcodeproj" \
  -scheme eSheepNext \
  -configuration Release > "$settings_file"

rg -q 'MARKETING_VERSION = 3\.1\.0' "$settings_file" || fail "MARKETING_VERSION must be 3.1.0"
rg -q 'PRODUCT_BUNDLE_IDENTIFIER = com\.sheepfarm\.ios' "$settings_file" || fail "Release App bundle identifier is incorrect"
rg -q 'APP_GROUP_IDENTIFIER = group\.com\.sheepfarm' "$settings_file" || fail "Release App Group is incorrect"
rg -q 'APS_ENVIRONMENT = production' "$settings_file" || fail "Release APNs environment is not production"
rg -q 'SUBSCRIPTIONS_ENABLED = NO' "$settings_file" || fail "subscriptions must remain disabled"
rg -q 'SUPABASE_ENABLED = YES' "$settings_file" || fail "Supabase must be enabled in Release"
resolved_supabase_url="$(awk -F ' = ' '/^[[:space:]]*SUPABASE_URL = / { print $2; exit }' "$settings_file")"
[[ "$resolved_supabase_url" == https://*.* ]] || fail "resolved Release SUPABASE_URL is malformed: $resolved_supabase_url"

DEVELOPER_DIR="$developer_dir" xcodebuild build \
  -project "$repo_root/eSheepNext.xcodeproj" \
  -scheme eSheepNext \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data/Release" \
  CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR="$developer_dir" xcodebuild test \
  -project "$repo_root/eSheepNext.xcodeproj" \
  -scheme eSheepNext \
  -configuration Debug \
  -destination "$test_destination" \
  -derivedDataPath "$derived_data/Tests" \
  -parallel-testing-enabled NO \
  -only-testing:eSheepNextTests/TMRWorkflowTests \
  -only-testing:eSheepNextTests/AppSchemaMigrationTests \
  -only-testing:eSheepNextTests/FarmRemoteRestoreAndStorageTests \
  -only-testing:eSheepNextTests/FarmRemoteSyncCoordinatorTests \
  -only-testing:eSheepNextTests/FarmSessionTests \
  CODE_SIGN_STYLE=Automatic

print -r -- "Internal TestFlight hard gate passed with Xcode $xcode_build."
print -r -- "Full sequential XCTest, local Supabase reset/pgTAP, signed-device validation and Archive validation remain separate required gates."
