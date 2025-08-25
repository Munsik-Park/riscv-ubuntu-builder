#!/usr/bin/env bash
# build_qemu_single.sh
# Build a single package in separate QEMU environment
# Usage: sudo ./build_qemu_single.sh <package_name>

set -euo pipefail

PACKAGE_NAME="${1:-}"
if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package_name>"
    echo "Example: $0 binutils"
    exit 1
fi

# ------------ Config ------------
SUITE="${SUITE:-noble}"
ARCH="${ARCH:-riscv64}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
BASE_WORKDIR="${BASE_WORKDIR:-/srv/qemu-builds}"
WORKDIR="$BASE_WORKDIR/$PACKAGE_NAME"
TARGET_ROOTFS="$WORKDIR/target-rootfs"
BUILDER_BASE="$WORKDIR/builder-base"
OUTDIR="$WORKDIR/out"
LOGDIR="$WORKDIR/logs"

IMG_NAME="ubuntu-rv-${PACKAGE_NAME}.qcow2"
IMG_SIZE="${IMG_SIZE:-4G}"

# Single package build
PKGS="$PACKAGE_NAME"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[!] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Build failed for package: $PACKAGE_NAME"
  else
    msg "Build completed for package: $PACKAGE_NAME"
  fi
  
  # Cleanup any remaining mounts
  for mp in "$WORKDIR"/{target-rootfs,builder-base}/{proc,sys,dev/pts,dev}; do
    if mountpoint -q "$mp" 2>/dev/null; then
      warn "Cleaning up mount: $mp"
      umount -l "$mp" 2>/dev/null || true
    fi
  done
}

trap cleanup_on_exit EXIT

# ------------ Main Build Process ------------
need_sudo

msg "Starting QEMU build for package: $PACKAGE_NAME"
msg "Working directory: $WORKDIR"

# Create directories
mkdir -p "$WORKDIR" "$TARGET_ROOTFS" "$OUTDIR" "$LOGDIR"

# Check if debootstrap is available
if ! command -v debootstrap >/dev/null 2>&1; then
  msg "Installing debootstrap..."
  apt-get update
  apt-get install -y debootstrap qemu-user-static binfmt-support
fi

# Create target rootfs
if [[ ! -f "$WORKDIR/.target_ready" ]]; then
  msg "Creating target rootfs for $PACKAGE_NAME..."
  debootstrap --arch="$ARCH" \
              --include=systemd,dbus,network-manager,openssh-server \
              "$SUITE" "$TARGET_ROOTFS" "$MIRROR" \
              2>&1 | tee "$LOGDIR/01_debootstrap_target.log"
  
  # Basic system configuration
  chroot "$TARGET_ROOTFS" /bin/bash <<'EOCHROOT'
set -e
echo 'root:root' | chpasswd
systemctl enable ssh
systemctl enable systemd-networkd
systemctl enable systemd-resolved
echo 'ubuntu-riscv' > /etc/hostname
EOCHROOT
  
  touch "$WORKDIR/.target_ready"
  msg "Target rootfs ready for $PACKAGE_NAME"
fi

# Create builder environment (copy of target)
if [[ ! -f "$WORKDIR/.builder_ready" ]]; then
  msg "Creating builder environment for $PACKAGE_NAME..."
  cp -a "$TARGET_ROOTFS" "$BUILDER_BASE"
  
  # Install build dependencies
  chroot "$BUILDER_BASE" /bin/bash <<EOCHROOT
set -e
apt-get update
apt-get install -y build-essential dpkg-dev debhelper
apt-get build-dep -y $PKGS || true
EOCHROOT
  
  touch "$WORKDIR/.builder_ready"
  msg "Builder environment ready for $PACKAGE_NAME"
fi

# Build the package (single-threaded, no parallel compilation)
msg "Building package: $PACKAGE_NAME (single-threaded build)"
chroot "$BUILDER_BASE" /bin/bash <<EOCHROOT
set -e
cd /tmp
export DEB_BUILD_OPTIONS="parallel=1 reproducible=+all"
apt-get source $PKGS
cd ${PKGS}-*
dpkg-buildpackage -us -uc -b -j1
cd ..
mkdir -p /out
cp *.deb /out/ 2>/dev/null || true
ls -la /out/
EOCHROOT

# Copy results
msg "Copying build results for $PACKAGE_NAME..."
cp -a "$BUILDER_BASE/tmp"/*.deb "$OUTDIR/" 2>/dev/null || true
cp -a "$BUILDER_BASE/out"/*.deb "$OUTDIR/" 2>/dev/null || true

# Create disk image
msg "Creating disk image for $PACKAGE_NAME..."
qemu-img create -f qcow2 "$WORKDIR/$IMG_NAME" "$IMG_SIZE"

# Install packages to target and create final image
msg "Installing $PACKAGE_NAME to target system..."
cp -a "$OUTDIR"/*.deb "$TARGET_ROOTFS/tmp/" 2>/dev/null || true
chroot "$TARGET_ROOTFS" /bin/bash <<EOCHROOT
set -e
cd /tmp
dpkg -i *.deb 2>/dev/null || true
apt-get install -f -y
EOCHROOT

msg "Package $PACKAGE_NAME build completed successfully!"
msg "Results in: $OUTDIR"
msg "Disk image: $WORKDIR/$IMG_NAME"