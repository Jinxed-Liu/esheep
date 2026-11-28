#!/bin/bash
# On the mini, carry only the two TLS connections used by Auth across the private guest.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
volume=/Volumes/ESheepProd28
expected=$(cat "$HOME/.esheep-migration-20261128/prod-volume-uuid")
[[ -n "$expected" && "$(diskutil info -plist "$volume" | plutil -extract VolumeUUID raw -)" == "$expected" ]]
exec ssh -F "$volume/lima/prod/ssh.config" -N -T -o BatchMode=yes -o ControlPath=none -o ControlMaster=no \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:14655:smtp.mx.cloudflare.net:465 \
  -R 127.0.0.1:14443:appleid.apple.com:443 lima-prod
