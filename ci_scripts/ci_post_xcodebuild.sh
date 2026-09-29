#!/bin/sh
# Validate the manual internal release; the opt-in maintenance workflow remains separate.
set -eu

if [ "${ESHEEP_TESTFLIGHT_RELEASE:-0}" = "1" ]; then
  [ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || exit 1
  [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 1
  [ "${CI_XCODEBUILD_EXIT_CODE:-1}" = "0" ] || exit 1
  archive_path="${CI_ARCHIVE_PATH:?Missing Cloud archive path}"
  app_path="$archive_path/Products/Applications/eSheepNext.app"
  app_info="$app_path/Info.plist"
  widget_info="$app_path/PlugIns/eSheepNextWidget.appex/Info.plist"
  [ -f "$app_info" ] && [ -f "$widget_info" ] || {
    echo 'Release archive is missing the app or widget.' >&2
    exit 1
  }

  plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
  require_plist_value() {
    actual="$(plist_value "$1" "$2")"
    if [ "$actual" != "$3" ]; then
      echo "Release archive has an unexpected $2 value." >&2
      exit 1
    fi
  }
  require_plist_value "$app_info" CFBundleIdentifier com.sheepfarm.ios
  require_plist_value "$app_info" CFBundleShortVersionString 3.2
  require_plist_value "$app_info" CFBundleVersion 51
  require_plist_value "$app_info" CFBundleDisplayName 'eSheep+'
  require_plist_value "$app_info" APP_ENVIRONMENT production
  require_plist_value "$app_info" ITSAppUsesNonExemptEncryption false
  require_plist_value "$app_info" SUPABASE_URL "${ESHEEP_RELEASE_SUPABASE_URL:?}"
  require_plist_value "$app_info" SUPABASE_PUBLISHABLE_KEY "${ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY:?}"
  require_plist_value "$widget_info" CFBundleIdentifier com.sheepfarm.ios.widget
  require_plist_value "$widget_info" CFBundleVersion 51
  codesign --verify --deep --strict "$app_path" >/dev/null
  echo 'Validated the signed Production app and widget in the Cloud archive.'
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
