#!/usr/bin/env bash
# build_riscv_ubuntu.sh
# One-shot script to build a QEMU-bootable Ubuntu 24.04 (riscv64) image,
# with selected packages built from source inside a clean RISC-V chroot.
# Host requirement: x86_64 Ubuntu 24.04 with sudo.
#
# Usage:
#   sudo bash build_riscv_ubuntu.sh
# Optional env vars:
#   SUITE=noble
#   ARCH=riscv64
#   MIRROR=http://ports.ubuntu.com/ubuntu-ports
#   WORKDIR=/srv/rvbuild
#   IMG_NAME=ubuntu-rv.qcow2
#   IMG_SIZE=4G
#   PKGS="bash coreutils ..."
#   KERNEL=./Image
#   INITRD=./initrd.img   # optional
#
# After build, you can boot with:
#   qemu-system-riscv64 -M virt -m 2048 -kernel $KERNEL -initrd $INITRD \
#     -append "root=/dev/vda rw console=ttyS0" \
#     -drive file=$IMG_NAME,format=qcow2,if=virtio \
#     -device virtio-net-device,netdev=n0 -netdev user,id=n0,hostfwd=tcp::2222-:22 \
#     -nographic
# And SSH:
#   ssh -p 2222 root@127.0.0.1   (password: root)
#
set -euo pipefail

# ------------ Config ------------
SUITE="${SUITE:-noble}"
ARCH="${ARCH:-riscv64}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
WORKDIR="${WORKDIR:-/srv/rvbuild}"
TARGET_ROOTFS="$WORKDIR/target-rootfs"
BUILDER_BASE="$WORKDIR/builder-base"
BUILDER_SNAP="$WORKDIR/builder-base.tar"
OUTDIR="$WORKDIR/out"
LOGDIR="$WORKDIR/logs"

IMG_NAME="${IMG_NAME:-ubuntu-rv.qcow2}"
IMG_SIZE="${IMG_SIZE:-4G}"

# Default package set (edit as needed)
PKGS="${PKGS:-bash coreutils grep sed findutils tar xz-utils e2fsprogs util-linux \
iproute2 netbase ca-certificates iputils-ping openssh-server \
binutils gdb}"

# Optional: user can export exact versions like PKG_VER_coreutils=9.4-3ubuntu2
# The build() function below will honor env var PKG_VER_<name> if set.

# Paths to host kernel/initrd for QEMU boot (user supplied)
KERNEL="${KERNEL:-}"
INITRD="${INITRD:-}"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[!] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

ensure_host_deps() {
  msg "Installing host dependencies..."
  apt-get update | tee "$LOGDIR/00_apt_update_host.log"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    debootstrap qemu-user-static binfmt-support qemu-system-misc \
    build-essential devscripts debhelper dpkg-dev fakeroot quilt \
    ubuntu-keyring debian-archive-keyring rsync e2fsprogs dosfstools \
    parted ca-certificates curl | tee "$LOGDIR/00_install_host_deps.log"
}

prepare_dirs() {
  mkdir -p "$WORKDIR" "$OUTDIR" "$LOGDIR"
}

write_sources() {
  local root="$1"
  cat > "$root/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe multiverse restricted
deb $MIRROR ${SUITE}-updates main universe multiverse restricted
deb $MIRROR ${SUITE}-security main universe multiverse restricted
deb-src $MIRROR $SUITE main universe multiverse restricted
deb-src $MIRROR ${SUITE}-updates main universe multiverse restricted
deb-src $MIRROR ${SUITE}-security main universe multiverse restricted
EOF
}

make_target_rootfs() {
  if [[ -d "$TARGET_ROOTFS" ]]; then
    msg "Target rootfs exists: $TARGET_ROOTFS (skipping debootstrap)"
  else
    msg "Creating target rootfs ($ARCH, $SUITE) at $TARGET_ROOTFS ..."
    mkdir -p "$TARGET_ROOTFS"
    debootstrap --arch="$ARCH" --foreign "$SUITE" "$TARGET_ROOTFS" "$MIRROR" | tee "$LOGDIR/01_debootstrap_target.log"
    cp /usr/bin/qemu-riscv64-static "$TARGET_ROOTFS/usr/bin/"
    chroot "$TARGET_ROOTFS" /debootstrap/debootstrap --second-stage | tee "$LOGDIR/02_second_stage_target.log"
    write_sources "$TARGET_ROOTFS"
    chroot "$TARGET_ROOTFS" apt-get update | tee "$LOGDIR/03_apt_update_target.log"
    msg "Installing minimal runtime into target (APT/SSH ready)..."
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET_ROOTFS" apt-get install -y \
      systemd-sysv openssh-server netbase iproute2 iputils-ping \
      ca-certificates sudo locales tzdata vim-tiny less | tee "$LOGDIR/04_minimal_runtime_target.log"
    chroot "$TARGET_ROOTFS" locale-gen en_US.UTF-8 || true
    echo ubuntu-rv > "$TARGET_ROOTFS/etc/hostname"
    chroot "$TARGET_ROOTFS" bash -lc "echo 'root:root' | chpasswd"
    chroot "$TARGET_ROOTFS" systemctl enable ssh || true
    mkdir -p "$TARGET_ROOTFS/etc/network/interfaces.d"
    cat > "$TARGET_ROOTFS/etc/network/interfaces.d/eth0" <<EOF
auto eth0
iface eth0 inet dhcp
EOF
  fi
}

make_builder_base() {
  if [[ -d "$BUILDER_BASE" && -f "$BUILDER_SNAP" ]]; then
    msg "Builder base and snapshot exist (skipping)"
    return
  fi
  msg "Creating builder base chroot at $BUILDER_BASE ..."
  mkdir -p "$BUILDER_BASE"
  debootstrap --arch="$ARCH" --foreign "$SUITE" "$BUILDER_BASE" "$MIRROR" | tee "$LOGDIR/11_debootstrap_builder.log"
  cp /usr/bin/qemu-riscv64-static "$BUILDER_BASE/usr/bin/"
  chroot "$BUILDER_BASE" /debootstrap/debootstrap --second-stage | tee "$LOGDIR/12_second_stage_builder.log"
  write_sources "$BUILDER_BASE"
  chroot "$BUILDER_BASE" apt-get update | tee "$LOGDIR/13_apt_update_builder.log"
  msg "Installing build toolchain into builder base..."
  DEBIAN_FRONTEND=noninteractive chroot "$BUILDER_BASE" apt-get install -y \
    build-essential devscripts debhelper dpkg-dev fakeroot quilt \
    ca-certificates pkg-config | tee "$LOGDIR/14_builder_tools.log"
  msg "Freezing builder snapshot..."
  tar -C "$(dirname "$BUILDER_BASE")" -cpf "$BUILDER_SNAP" "$(basename "$BUILDER_BASE")"
}

cleanup_mounts() {
  [[ -d "$WORKDIR/builder" ]] || return 0
  msg "Cleaning up mount points..."
  
  # Check if mount points exist and are mounted before attempting umount
  mountpoint -q "$WORKDIR/builder/dev/pts" && umount "$WORKDIR/builder/dev/pts" 2>/dev/null || true
  mountpoint -q "$WORKDIR/builder/dev" && umount "$WORKDIR/builder/dev" 2>/dev/null || true
  mountpoint -q "$WORKDIR/builder/sys" && umount "$WORKDIR/builder/sys" 2>/dev/null || true
  mountpoint -q "$WORKDIR/builder/proc" && umount "$WORKDIR/builder/proc" 2>/dev/null || true
}

reset_builder() {
  # Clean up any existing mounts before reset
  cleanup_mounts
  rm -rf "$WORKDIR/builder"
  tar -C "$WORKDIR" -xpf "$BUILDER_SNAP"
  mv "$WORKDIR/$(basename "$BUILDER_BASE")" "$WORKDIR/builder"
}

build_one() {
  local pkg="$1"
  local var="PKG_VER_${pkg//[-+.]/_}"
  local ver="${!var:-}"
  local ver_clause=""
  [[ -n "$ver" ]] && ver_clause="=$ver"

  msg "Building from source: $pkg${ver_clause}"
  reset_builder

  # Setup cleanup trap for this build
  trap 'cleanup_mounts; exit 1' INT TERM EXIT

  # Mount necessary filesystems for build
  mount -t proc proc "$WORKDIR/builder/proc" || true
  mount -t sysfs sysfs "$WORKDIR/builder/sys" || true  
  mount -t devtmpfs dev "$WORKDIR/builder/dev" || true
  mount -t devpts devpts "$WORKDIR/builder/dev/pts" || true

  # Set QEMU stability configuration
  export QEMU_CPU=rv64,sv39=off
  
  chroot "$WORKDIR/builder" bash -lc "
    set -e
    export DEB_BUILD_OPTIONS=\"parallel=80\"
    apt-get update
    apt-get build-dep -y ${pkg}
    apt-get source ${pkg}${ver_clause}
    cd \$(find . -maxdepth 1 -type d -name '${pkg}-*' | sort | head -n1)
    dpkg-buildpackage -us -uc -b -j80
  " | tee "$LOGDIR/20_build_${pkg}.log"

  # Normal cleanup (trap will also handle emergency cleanup)
  cleanup_mounts

  # Clear trap after successful cleanup
  trap - INT TERM EXIT

  mkdir -p "$OUTDIR/$pkg"
  find "$WORKDIR/builder" -maxdepth 1 -type f -name '*.deb' -exec cp {} "$OUTDIR/$pkg/" \;
}

install_into_target() {
  local pkg="$1"
  msg "Installing built package into target: $pkg"
  mkdir -p "$TARGET_ROOTFS/host-out"
  mount --bind "$OUTDIR/$pkg" "$TARGET_ROOTFS/host-out"
  # ensure qemu-static present
  cp /usr/bin/qemu-riscv64-static "$TARGET_ROOTFS/usr/bin/" || true
  chroot "$TARGET_ROOTFS" bash -lc "
    set -e
    dpkg -i /host-out/*.deb || apt-get -f -y install
  " | tee "$LOGDIR/30_install_${pkg}.log"
  umount "$TARGET_ROOTFS/host-out"
}

build_and_install_loop() {
  for p in $PKGS; do
    build_one "$p"
    install_into_target "$p"
  done
}

validate_img_name() {
  # Prevent overwriting system files
  case "$IMG_NAME" in
    /dev/*|/sys/*|/proc/*|/etc/*|/bin/*|/sbin/*|/usr/*|/var/*|/tmp/*)
      err "IMG_NAME cannot point to system directories: $IMG_NAME"
      exit 1
      ;;
    /*)
      # Absolute path - ensure parent directory exists and is writable
      local parent_dir
      parent_dir=$(dirname "$IMG_NAME")
      if [[ ! -w "$parent_dir" ]]; then
        err "Cannot write to directory: $parent_dir"
        exit 1
      fi
      ;;
  esac
}

make_qcow2() {
  validate_img_name
  msg "Creating qcow2 image: $IMG_NAME ($IMG_SIZE)"
  local tmpdir; tmpdir=$(mktemp -d)
  local raw="$tmpdir/root.raw"
  {
    echo "[$(date)] Creating raw image: $raw ($IMG_SIZE)"
    truncate -s "$IMG_SIZE" "$raw"
    echo "[$(date)] Formatting with ext4"
    mkfs.ext4 -F "$raw"
    echo "[$(date)] Mounting raw image at: $tmpdir"
    mount -o loop "$raw" "$tmpdir"
    echo "[$(date)] Syncing rootfs contents"
    rsync -aHAX "$TARGET_ROOTFS"/ "$tmpdir"/
    echo "[$(date)] Creating fstab"
    echo "/dev/vda / ext4 defaults 0 1" > "$tmpdir/etc/fstab"
    echo "[$(date)] Unmounting"
    umount "$tmpdir"
    echo "[$(date)] Converting to qcow2"
    qemu-img convert -f raw -O qcow2 "$raw" "$IMG_NAME"
    echo "[$(date)] Cleaning up"
    rm -rf "$tmpdir"
    echo "[$(date)] Image creation completed: $IMG_NAME"
  } | tee "$LOGDIR/50_qcow2_creation.log"
  msg "Image created: $IMG_NAME"
}

print_boot_help() {
  echo
  echo "=== QEMU Boot Help ==="
  echo "Provide a RISC-V kernel Image (and optional initrd) on the host."
  echo "Example:"
  echo "  qemu-system-riscv64 -M virt -m 2048 \\
  -kernel \$KERNEL -initrd \$INITRD \\
  -append \"root=/dev/vda rw console=ttyS0\" \\
  -drive file=$IMG_NAME,format=qcow2,if=virtio \\
  -device virtio-net-device,netdev=n0 -netdev user,id=n0,hostfwd=tcp::2222-:22 \\
  -nographic"
  echo "SSH after boot: ssh -p 2222 root@127.0.0.1 (password: root)"
}

record_minimal_logs() {
  msg "Recording minimal reproducibility logs from target and builder..."
  mkdir -p "$WORKDIR/records"
  for root in "$TARGET_ROOTFS" "$WORKDIR/builder"; do
    [[ -d "$root" ]] || continue
    local tag; tag=$(basename "$root")
    chroot "$root" bash -lc "apt-cache policy" > "$WORKDIR/records/${tag}_apt-cache-policy.txt" || true
    chroot "$root" bash -lc "dpkg -l" > "$WORKDIR/records/${tag}_dpkg-l.txt" || true
    cp "$root/etc/apt/sources.list" "$WORKDIR/records/${tag}_sources.list" || true
  done
  msg "Logs at: $WORKDIR/records"
}

main() {
  need_sudo
  prepare_dirs
  
  # Setup global cleanup trap
  trap 'cleanup_mounts; err "Build interrupted - cleaning up mounts"; exit 1' INT TERM
  
  # Start comprehensive logging
  {
    echo "========================================"
    echo "RISC-V Ubuntu Build Started: $(date)"
    echo "========================================"
    echo "Host: $(uname -a)"
    echo "Script: $0"
    echo "Args: $*"
    echo "Config:"
    echo "  SUITE=$SUITE"
    echo "  ARCH=$ARCH"
    echo "  WORKDIR=$WORKDIR"
    echo "  PKGS=$PKGS"
    echo "========================================"
    echo ""
  } | tee "$LOGDIR/00_main_execution.log"
  
  ensure_host_deps
  make_target_rootfs
  make_builder_base
  build_and_install_loop
  make_qcow2
  record_minimal_logs
  print_boot_help
  
  {
    echo ""
    echo "========================================"
    echo "RISC-V Ubuntu Build Completed: $(date)"
    echo "========================================"
  } | tee -a "$LOGDIR/00_main_execution.log"
  
  msg "DONE. Full logs available in: $LOGDIR/"
}

main "$@"
