#!/bin/sh
# Opt-in maintenance workflow only; ordinary application builds are unchanged.
set -eu
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
