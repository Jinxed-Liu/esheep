#!/bin/sh
# Validate internal archives; keep opt-in checkpoint maintenance independent.
set -eu

if [ "${ESHEEP_TESTFLIGHT_RELEASE:-0}" = "1" ]; then
  [ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || exit 1
  [ "${CI_WORKFLOW:-}" = "TestFlight 3.2 Internal" ] || exit 1
  [ "${CI_BRANCH:-}" = "main" ] || exit 1
  [ -z "${CI_PULL_REQUEST_NUMBER:-}" ] || exit 1
  [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 1
  [ "${CI_XCODEBUILD_EXIT_CODE:-1}" = "0" ] || exit 1
  archive_path="${CI_ARCHIVE_PATH:?Missing Cloud archive path}"
  build_number="${CI_BUILD_NUMBER:?Missing Cloud build number}"
  expected_version="${ESHEEP_TESTFLIGHT_VERSION:-3.2}"
  app_path="$archive_path/Products/Applications/eSheepNext.app"
  app_info="$app_path/Info.plist"
  widget_path="$app_path/PlugIns/eSheepNextWidget.appex"
  widget_info="$widget_path/Info.plist"
  [ -f "$app_info" ] && [ -f "$widget_info" ] || {
    echo 'Release archive is missing the app or widget.' >&2
    exit 1
  }
  require_plist_value() {
    actual="$(/usr/libexec/PlistBuddy -c "Print :$2" "$1")"
    if [ "$actual" != "$3" ]; then
      echo "Release archive has an unexpected $2 value." >&2
      exit 1
    fi
  }
  require_plist_value "$app_info" CFBundleIdentifier com.sheepfarm.ios
  require_plist_value "$app_info" CFBundleShortVersionString "$expected_version"
  require_plist_value "$app_info" CFBundleVersion "$build_number"
  require_plist_value "$app_info" CFBundleDisplayName 'eSheep+'
  require_plist_value "$app_info" APP_ENVIRONMENT production
  require_plist_value "$app_info" ITSAppUsesNonExemptEncryption false
  require_plist_value "$app_info" SUPABASE_URL "${ESHEEP_RELEASE_SUPABASE_URL:?}"
  require_plist_value "$app_info" SUPABASE_PUBLISHABLE_KEY "${ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY:?}"
  require_plist_value "$app_info" SUBSCRIPTIONS_ENABLED NO
  require_plist_value "$widget_info" CFBundleIdentifier com.sheepfarm.ios.widget
  require_plist_value "$widget_info" CFBundleShortVersionString "$expected_version"
  require_plist_value "$widget_info" CFBundleVersion "$build_number"
  codesign --verify --deep --strict "$app_path" >/dev/null
  codesign --verify --strict "$widget_path" >/dev/null
  /usr/bin/lipo -verify_arch arm64 "$app_path/eSheepNext"
  /usr/bin/lipo -verify_arch arm64 "$widget_path/eSheepNextWidget"
  echo "Validated signed Production app and widget: $expected_version ($build_number)."
  exit 0
fi

[ "${ESHEEP_CHECKPOINT_REFRESH:-0}" = "1" ] || exit 0
[ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || { echo 'Xcode Cloud environment required'; exit 1; }
[ "${CI_XCODEBUILD_EXIT_CODE:-1}" = "0" ] || exit 1
[ "${CI_XCODEBUILD_ACTION:-}" = "build-for-testing" ] || exit 0
case "${CI_START_CONDITION:-}" in schedule|manual|manual_rebuild) ;; *) echo 'Maintenance runs require a schedule or manual trigger'; exit 1 ;; esac
[ -z "${CI_PULL_REQUEST_NUMBER:-}" ] || exit 1
[ "${CI_BRANCH:-}" = "main" ] || { echo 'Maintenance runs require the protected main branch'; exit 1; }
: "${ESHEEP_CHECKPOINT_SERVICE_KEY:?Set the project service key as an Xcode Cloud secret}"
: "${ESHEEP_CHECKPOINT_PROJECT:?Set the production project reference}"
umask 077
cd "$(dirname "$0")"
if ! command -v node >/dev/null 2>&1; then
  brew install node@24
  PATH="$(brew --prefix node@24)/bin:$PATH"
  export PATH
fi
python3 run_checkpoint_refresh.py
