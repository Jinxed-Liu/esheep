#!/usr/bin/env bash
# Install the two Ubuntu 24.04 tools used by verify_local.sh.
set -euo pipefail

if command -v rg >/dev/null && [[ -x /bin/zsh ]]; then
  exit 0
fi

# Use only Ubuntu-signed packages. Keep the runner's system sources untouched;
# an unavailable Azure mirror must not block all four verification jobs.
scratch=$(mktemp -d)
trap 'sudo rm -rf -- "$scratch"' EXIT
chmod 755 "$scratch"
for mirror in https://archive.ubuntu.com/ubuntu https://mirrors.edge.kernel.org/ubuntu; do
  echo "Installing verification tools from $mirror"
  printf 'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] %s noble main universe\n' "$mirror" > "$scratch/ubuntu.list"
  printf 'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] %s noble-updates main universe\n' "$mirror" >> "$scratch/ubuntu.list"
  printf 'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] %s noble-security main universe\n' "$mirror" >> "$scratch/ubuntu.list"
  lists=$(mktemp -d "$scratch/lists.XXXXXX")
  chmod 755 "$lists"
  options=(-o "Dir::Etc::sourcelist=$scratch/ubuntu.list" -o 'Dir::Etc::sourceparts=-'
    -o "Dir::State::lists=$lists" -o 'Acquire::Retries=0' -o 'Acquire::https::Timeout=15'
    -o 'APT::Update::Error-Mode=any')
  if sudo apt-get "${options[@]}" update &&
     sudo apt-get "${options[@]}" install --yes --no-install-recommends ripgrep zsh &&
     command -v rg >/dev/null && [[ -x /bin/zsh ]]; then
    exit 0
  fi
done
echo "Unable to install the verification tools from either signed Ubuntu mirror." >&2
exit 1
