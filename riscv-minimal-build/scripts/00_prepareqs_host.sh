#!/usr/bin/env bash
set -euo pipefail
sudo apt update
sudo apt install -y germinate botch dose-extra debtree graphviz \
  aptly gnupg2 devscripts build-essential \
  sbuild schroot debootstrap mmdebstrap \
  qemu-system-misc qemu-utils cloud-image-utils \
  ca-certificates rsync jq moreutils
