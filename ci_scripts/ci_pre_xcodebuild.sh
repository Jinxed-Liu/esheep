#!/bin/sh
set -eu

# Only the manual internal TestFlight workflow prepares this ignored public
# Release configuration. Ordinary Xcode Cloud builds remain unchanged.
[ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || exit 0
[ "${ESHEEP_TESTFLIGHT_RELEASE:-0}" = "1" ] || exit 0

if [ "${CI_WORKFLOW:-}" != "TestFlight 3.2 Internal" ] ||
   [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo 'Internal release configuration is limited to its archive workflow.' >&2
  exit 1
fi
case "${CI_START_CONDITION:-}" in
  manual|manual_rebuild) ;;
  *) echo 'Internal release requires a manual Cloud run.' >&2; exit 1 ;;
esac
if [ -n "${CI_BUILD_NUMBER:-}" ] && [ "$CI_BUILD_NUMBER" != "51" ]; then
  echo 'Cloud build number changed; update and revalidate the release source.' >&2
  exit 1
fi

url="${ESHEEP_RELEASE_SUPABASE_URL:?Missing Release Supabase URL}"
key="${ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY:?Missing Release publishable key}"
case "$url" in
  https://*.supabase.co) ;;
  *) echo 'Invalid Release Supabase URL.' >&2; exit 1 ;;
esac
host="${url#https://}"
case "$host" in
  ''|*/*) echo 'Invalid Release Supabase host.' >&2; exit 1 ;;
esac
if ! printf '%s' "$key" | grep -Eq '^sb_publishable_[A-Za-z0-9_-]+$'; then
  echo 'Invalid Release publishable key.' >&2
  exit 1
fi

repo_root="${CI_PRIMARY_REPOSITORY_PATH:?Missing Cloud repository path}"
[ -f "$repo_root/Config/ReleaseEnvironment.xcconfig" ] || {
  echo 'Release project configuration is unavailable in the Cloud checkout.' >&2
  exit 1
}
release_config="$repo_root/Config/ReleaseEnvironment.local.xcconfig"
umask 077
temporary_config="$(mktemp "$repo_root/Config/.ReleaseEnvironment.local.xcconfig.XXXXXX")"
trap 'rm -f "$temporary_config"' EXIT HUP INT TERM
printf 'SUPABASE_URL = https:$(XC_SLASH)$(XC_SLASH)%s\nSUPABASE_PUBLISHABLE_KEY = %s\nSUPABASE_ENABLED = YES\n' \
  "$host" "$key" > "$temporary_config"
mv -f "$temporary_config" "$release_config"
echo 'Prepared the ignored Production Release configuration for the Cloud archive.'
