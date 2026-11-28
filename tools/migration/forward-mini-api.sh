#!/bin/bash
# Private origin for the existing tunnel. The SSH listener binds only on the mini.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
volume=/Volumes/ESheepProd28
expected_uuid=$(cat "$HOME/.esheep-migration-20261128/prod-volume-uuid")
actual_uuid=$(diskutil info -plist "$volume" | plutil -extract VolumeUUID raw -)
[[ -n "$expected_uuid" && "$actual_uuid" == "$expected_uuid" ]]
export LIMA_HOME="$volume/lima"
lima="$HOME/.esheep-mini-lab/tools-2.3.0/bin/limactl"
gateway=$("$lima" shell --workdir=/ prod sudo docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' supabase-envoy)
[[ "$gateway" =~ ^172\.30\.91\.[0-9]{1,3}$ ]]
exec ssh -F "$LIMA_HOME/prod/ssh.config" -N -T -o BatchMode=yes -o ControlPath=none -o ControlMaster=no \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
  -L "127.0.0.1:17858:$gateway:8000" lima-prod
