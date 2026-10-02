#!/bin/sh
set -eu

# Prepare Production inputs only for the dedicated manual internal archive.
[ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || exit 0
[ "${ESHEEP_TESTFLIGHT_RELEASE:-0}" = "1" ] || exit 0
[ "${CI_WORKFLOW:-}" = "TestFlight 3.2 Internal" ] || {
  echo 'Internal releases require the dedicated TestFlight workflow.' >&2
  exit 1
}
[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 1
[ "${CI_BRANCH:-}" = "main" ] || {
  echo 'Internal releases require the main branch.' >&2
  exit 1
}
[ -z "${CI_PULL_REQUEST_NUMBER:-}" ] || exit 1
case "${CI_START_CONDITION:-}" in
  manual|manual_rebuild) ;;
  *) echo 'Internal releases require a manual Cloud run.' >&2; exit 1 ;;
esac

build_number="${CI_BUILD_NUMBER:?Missing Cloud build number}"
case "$build_number" in
  ''|0*|*[!0-9]*) echo 'Invalid Cloud build number.' >&2; exit 1 ;;
esac
url="${ESHEEP_RELEASE_SUPABASE_URL:?Missing Release Supabase URL}"
key="${ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY:?Missing Release publishable key}"
case "$url" in
  https://*.supabase.co) ;;
  *) echo 'Invalid Release Supabase URL.' >&2; exit 1 ;;
esac
host="${url#https://}"
case "$host" in
  ''|*/*|*[!A-Za-z0-9.-]*) echo 'Invalid Release Supabase host.' >&2; exit 1 ;;
esac
if ! printf '%s' "$key" | grep -Eq '^sb_publishable_[A-Za-z0-9_-]+$'; then
  echo 'Invalid Release publishable key.' >&2
  exit 1
fi

repo_root="${CI_PRIMARY_REPOSITORY_PATH:?Missing Cloud repository path}"
[ -f "$repo_root/Config/ReleaseEnvironment.xcconfig" ] || exit 1
umask 077
temporary_config="$(mktemp "$repo_root/Config/.ReleaseEnvironment.local.xcconfig.XXXXXX")"
trap 'rm -f "$temporary_config"' EXIT HUP INT TERM
printf 'SUPABASE_URL = https:$(XC_SLASH)$(XC_SLASH)%s\nSUPABASE_PUBLISHABLE_KEY = %s\nSUPABASE_ENABLED = YES\n' \
  "$host" "$key" > "$temporary_config"
mv -f "$temporary_config" "$repo_root/Config/ReleaseEnvironment.local.xcconfig"

# Change only the ephemeral Cloud checkout. Local project versions stay intact.
python3 - "$repo_root/eSheepNext.xcodeproj/project.pbxproj" "$build_number" <<'PY'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1])
source = project.read_text()
updated, count = re.subn(
    r"CURRENT_PROJECT_VERSION\s*=\s*\d+;",
    f"CURRENT_PROJECT_VERSION = {sys.argv[2]};",
    source,
)
if count < 2:
    raise SystemExit("App and Widget version settings are unavailable.")
project.write_text(updated)
PY
echo "Prepared Production configuration and Cloud build $build_number for the internal archive."
