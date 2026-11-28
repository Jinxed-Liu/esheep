#!/bin/bash
# User LaunchAgent on the Mac mini. FileVault and the login keychain must be unlocked.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
config="$HOME/.esheep-migration-20261128"
volume=/Volumes/ESheepProd28
image="$config/formal-production.sparsebundle"
expected_uuid=$(cat "$config/prod-volume-uuid")
[[ -n "$expected_uuid" && -d "$image" ]]
if [[ ! -d "$volume" ]]; then
  password=$(security find-generic-password -a "$(id -un)" -s eSheep-Mini-Prod28-Volume -w)
  printf '%s' "$password" | hdiutil attach -stdinpass -nobrowse -owners on "$image" >/dev/null
  unset password
fi
actual_uuid=$(diskutil info -plist "$volume" | plutil -extract VolumeUUID raw -)
[[ "$actual_uuid" == "$expected_uuid" ]]
export LIMA_HOME="$volume/lima"
lima="$HOME/.esheep-mini-lab/tools-2.3.0/bin/limactl"
[[ -f "$LIMA_HOME/prod/lima.yaml" ]]
if [[ "$("$lima" list --format '{{.Status}}' prod)" != Running ]]; then
  "$lima" start --tty=false prod
fi
"$lima" shell --workdir=/ prod sudo sh -ec '
  test "$(hostname -s)" = lima-prod
  cd /opt/esheep-production
  ./compose --profile functions up -d --no-build --pull never --no-recreate --wait --wait-timeout 180 db auth rest imgproxy storage realtime api-gw functions
'
