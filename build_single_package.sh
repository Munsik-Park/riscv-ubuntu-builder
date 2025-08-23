#!/usr/bin/env bash
# build_single_package.sh
# Build a single RISC-V package from source in an isolated environment
# Supports parallel execution with separate BUILD_ROOT_DIR instances
#
# Usage:
#   sudo bash build_single_package.sh <package_name> [BUILD_ROOT_DIR]
#
# Examples:
#   sudo bash build_single_package.sh bash                    # → /srv/rvbuild-bash/
#   sudo bash build_single_package.sh coreutils               # → /srv/rvbuild-coreutils/
#   BUILD_BASE_DIR=/custom sudo bash build_single_package.sh bash # → /custom/rvbuild-bash/
#
# Environment variables:
#   BUILD_BASE_DIR=/srv (base directory for all builds)
#   SUITE=noble
#   ARCH=riscv64
#   MIRROR=http://ports.ubuntu.com/ubuntu-ports
#   BUILD_PARALLEL=20
#
set -euo pipefail

# ------------ Argument validation ------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <package_name> [BUILD_ROOT_DIR]"
  echo "Example: $0 bash"
  echo "Example: $0 bash /custom/build/path"
  exit 1
fi

PACKAGE="$1"
BUILD_BASE_DIR="${BUILD_BASE_DIR:-/srv}"
BUILD_ROOT_DIR="${2:-$BUILD_BASE_DIR/rvbuild-$PACKAGE}"

# ------------ Config ------------
SUITE="${SUITE:-noble}"
ARCH="${ARCH:-riscv64}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
BUILD_PARALLEL="${BUILD_PARALLEL:-$(($(nproc)/4))}"

# All paths relative to BUILD_ROOT_DIR
TARGET_ROOTFS="$BUILD_ROOT_DIR/target-rootfs"
BUILDER_BASE="$BUILD_ROOT_DIR/builder-base"
BUILDER_SNAP="$BUILD_ROOT_DIR/builder-base.tar"
BUILDER_WORK="$BUILD_ROOT_DIR/builder"
OUTDIR="$BUILD_ROOT_DIR/out"
LOGDIR="$BUILD_ROOT_DIR/logs"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] [$$] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] [$$] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] [$$] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

validate_pkg_name() {
  local pkg="$1"
  if [[ ! "$pkg" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.-]*$ ]]; then
    err "Invalid package name: $pkg"
    exit 1
  fi
}

ensure_host_deps() {
  # Skip if already installed by build_parallel.sh
  if [[ "${SKIP_HOST_DEPS:-0}" == "1" ]]; then
    msg "Host dependencies already installed, skipping..."
    return 0
  fi
  
  msg "Installing host dependencies..."
  apt-get update &>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    debootstrap qemu-user-static binfmt-support qemu-system-misc \
    build-essential devscripts debhelper dpkg-dev fakeroot quilt \
    ubuntu-keyring debian-archive-keyring rsync e2fsprogs dosfstools \
    parted ca-certificates curl &>/dev/null
}

prepare_dirs() {
  mkdir -p "$BUILD_ROOT_DIR" "$OUTDIR" "$LOGDIR"
  msg "Using BUILD_ROOT_DIR: $BUILD_ROOT_DIR"
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
    debootstrap --arch="$ARCH" --foreign "$SUITE" "$TARGET_ROOTFS" "$MIRROR" \
      &> "$LOGDIR/01_debootstrap_target.log"
    cp /usr/bin/qemu-riscv64-static "$TARGET_ROOTFS/usr/bin/"
    chroot "$TARGET_ROOTFS" /debootstrap/debootstrap --second-stage \
      &> "$LOGDIR/02_second_stage_target.log"
    write_sources "$TARGET_ROOTFS"
    chroot "$TARGET_ROOTFS" apt-get update &> "$LOGDIR/03_apt_update_target.log"
    
    msg "Installing minimal runtime into target..."
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET_ROOTFS" apt-get install -y \
      systemd-sysv openssh-server netbase iproute2 iputils-ping \
      ca-certificates sudo locales tzdata vim-tiny less \
      &> "$LOGDIR/04_minimal_runtime_target.log"
    
    chroot "$TARGET_ROOTFS" locale-gen en_US.UTF-8 || true
    echo "ubuntu-rv-$PACKAGE" > "$TARGET_ROOTFS/etc/hostname"
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
  debootstrap --arch="$ARCH" --foreign "$SUITE" "$BUILDER_BASE" "$MIRROR" \
    &> "$LOGDIR/11_debootstrap_builder.log"
  cp /usr/bin/qemu-riscv64-static "$BUILDER_BASE/usr/bin/"
  chroot "$BUILDER_BASE" /debootstrap/debootstrap --second-stage \
    &> "$LOGDIR/12_second_stage_builder.log"
  write_sources "$BUILDER_BASE"
  chroot "$BUILDER_BASE" apt-get update &> "$LOGDIR/13_apt_update_builder.log"
  
  msg "Installing build toolchain into builder base..."
  DEBIAN_FRONTEND=noninteractive chroot "$BUILDER_BASE" apt-get install -y \
    build-essential devscripts debhelper dpkg-dev fakeroot quilt \
    ca-certificates pkg-config &> "$LOGDIR/14_builder_tools.log"
  
  msg "Freezing builder snapshot..."
  tar -C "$(dirname "$BUILDER_BASE")" -cpf "$BUILDER_SNAP" "$(basename "$BUILDER_BASE")"
}

safe_umount_single() {
  local mount_point="$1"
  local max_retries="${2:-3}"
  local retry_count=0
  
  # Check if mount point exists and is mounted
  if [[ ! -d "$mount_point" ]] || ! mountpoint -q "$mount_point" 2>/dev/null; then
    return 0
  fi
  
  while [[ $retry_count -lt $max_retries ]]; do
    # Check for processes using this mount point
    if command -v lsof >/dev/null 2>&1; then
      local lsof_result
      lsof_result=$(lsof +D "$mount_point" 2>/dev/null || true)
      if [[ -n "$lsof_result" ]]; then
        warn "Mount point $mount_point is in use, waiting..."
        sleep 2
        ((retry_count++))
        continue
      fi
    fi
    
    # Try normal umount first
    if umount "$mount_point" 2>/dev/null; then
      return 0
    fi
    
    # Try lazy umount
    if umount -l "$mount_point" 2>/dev/null; then
      warn "Used lazy umount for: $mount_point"
      return 0
    fi
    
    ((retry_count++))
    if [[ $retry_count -lt $max_retries ]]; then
      warn "Umount failed for $mount_point, retrying in 1 second..."
      sleep 1
    fi
  done
  
  warn "Failed to unmount $mount_point after $max_retries attempts"
  return 1
}

cleanup_mounts() {
  [[ -d "$BUILDER_WORK" ]] || return 0
  msg "Cleaning up mount points..."
  
  # Install lsof if not available for safer cleanup
  if ! command -v lsof >/dev/null 2>&1; then
    apt-get install -y lsof >/dev/null 2>&1 || true
  fi
  
  # Unmount in reverse order (deepest first)
  local mount_points=(
    "$BUILDER_WORK/dev/pts"
    "$BUILDER_WORK/dev"
    "$BUILDER_WORK/sys"
    "$BUILDER_WORK/proc"
  )
  
  local failed_count=0
  for mount_point in "${mount_points[@]}"; do
    if ! safe_umount_single "$mount_point" 3; then
      ((failed_count++))
    fi
  done
  
  if [[ $failed_count -gt 0 ]]; then
    warn "$failed_count mount points could not be cleaned up properly"
    return 1
  fi
}

reset_builder() {
  # Clean up any existing mounts before reset
  cleanup_mounts
  rm -rf "$BUILDER_WORK"
  tar -C "$BUILD_ROOT_DIR" -xpf "$BUILDER_SNAP"
  mv "$BUILD_ROOT_DIR/$(basename "$BUILDER_BASE")" "$BUILDER_WORK"
}

setup_mounts() {
  msg "Setting up build environment mounts..."
  
  # Mount necessary filesystems for build (fail if any mount fails)
  mkdir -p "$BUILDER_WORK/proc" "$BUILDER_WORK/sys" "$BUILDER_WORK/dev/pts"
  
  msg "Mounting /proc..."
  mount --bind /proc "$BUILDER_WORK/proc" || mount -t proc proc "$BUILDER_WORK/proc" || {
    err "Failed to mount /proc - aborting to prevent system contamination"
    exit 1
  }
  
  msg "Mounting /sys..."
  mount --bind /sys "$BUILDER_WORK/sys" || mount -t sysfs sysfs "$BUILDER_WORK/sys" || {
    err "Failed to mount /sys - aborting to prevent system contamination"
    cleanup_mounts
    exit 1
  }
  
  msg "Mounting /dev..."
  # Use private mount namespace to prevent host contamination
  mount -t tmpfs tmpfs "$BUILDER_WORK/dev" || {
    err "Failed to create tmpfs /dev - aborting to prevent system contamination"
    cleanup_mounts
    exit 1
  }
  
  # Create essential device nodes
  mknod "$BUILDER_WORK/dev/null" c 1 3
  mknod "$BUILDER_WORK/dev/zero" c 1 5
  mknod "$BUILDER_WORK/dev/random" c 1 8
  mknod "$BUILDER_WORK/dev/urandom" c 1 9
  mknod "$BUILDER_WORK/dev/tty" c 5 0
  chmod 666 "$BUILDER_WORK/dev/null" "$BUILDER_WORK/dev/zero" "$BUILDER_WORK/dev/random" "$BUILDER_WORK/dev/urandom" "$BUILDER_WORK/dev/tty"
  
  msg "Creating essential /dev entries..."
  # Ensure critical /dev entries exist
  [[ -e "$BUILDER_WORK/dev/stdin" ]] || ln -sf /proc/self/fd/0 "$BUILDER_WORK/dev/stdin"
  [[ -e "$BUILDER_WORK/dev/stdout" ]] || ln -sf /proc/self/fd/1 "$BUILDER_WORK/dev/stdout"
  [[ -e "$BUILDER_WORK/dev/stderr" ]] || ln -sf /proc/self/fd/2 "$BUILDER_WORK/dev/stderr"
  [[ -d "$BUILDER_WORK/dev/fd" ]] || ln -sf /proc/self/fd "$BUILDER_WORK/dev/fd"
  
  msg "Mounting /dev/pts..."
  mkdir -p "$BUILDER_WORK/dev/pts"
  mount -t devpts -o newinstance,ptmxmode=0666,mode=620,gid=5 devpts "$BUILDER_WORK/dev/pts" || {
    err "Failed to mount /dev/pts - aborting to prevent system contamination"
    cleanup_mounts
    exit 1
  }
  # Create ptmx device
  mknod "$BUILDER_WORK/dev/ptmx" c 5 2
  chmod 666 "$BUILDER_WORK/dev/ptmx"
}

build_package() {
  local pkg="$1"
  local var="PKG_VER_${pkg//[-+.]/_}"
  local ver="${!var:-}"
  local ver_clause=""
  [[ -n "$ver" ]] && ver_clause="=$ver"

  # Check if package is already built
  if [[ -d "$OUTDIR/$pkg" && $(find "$OUTDIR/$pkg" -name "*.deb" | wc -l) -gt 0 ]]; then
    msg "Package already built: $pkg (found $(find "$OUTDIR/$pkg" -name "*.deb" | wc -l) packages)"
    msg "To rebuild, remove $OUTDIR/$pkg or use FORCE_REBUILD=1"
    
    if [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
      msg "Skipping build for: $pkg"
      exit 2  # Special exit code for "already built"
    else
      msg "FORCE_REBUILD=1 set, rebuilding: $pkg"
      rm -rf "$OUTDIR/$pkg"
    fi
  fi

  # Record build start time
  local build_start_time=$(date +%s)
  local build_start_readable=$(date)
  msg "Building package from source: $pkg${ver_clause}"
  msg "Build started at: $build_start_readable"
  
  # Reset builder environment
  reset_builder

  # Setup cleanup trap for this build
  trap 'cleanup_mounts; exit 1' INT TERM EXIT

  # Setup mounts
  setup_mounts

  # Set QEMU stability configuration  
  export QEMU_CPU=rv64
  
  msg "Starting build in chroot..."
  chroot "$BUILDER_WORK" bash -lc "
    set -e
    export DEB_BUILD_OPTIONS=\"parallel=$BUILD_PARALLEL\"
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_OFFLINE=1
    
    # Fix RISC-V configure issues for GNU packages (tar, coreutils, etc.)
    # These functions exist but runtime tests fail in QEMU emulation
    export ac_cv_func_mkfifoat=yes
    export ac_cv_func_mknodat=yes
    export ac_cv_func_openat=yes
    export ac_cv_func_fstatat=yes
    export ac_cv_func_unlinkat=yes
    export ac_cv_func_renameat=yes
    export ac_cv_func_symlinkat=yes
    export ac_cv_func_readlinkat=yes
    
    dpkg --configure -a || true
    apt-get update
    apt-get build-dep -y ${pkg}
    apt-get source ${pkg}${ver_clause}
    # Find source directory: exclude system directories, find package-version pattern
    source_dir=\$(find . -maxdepth 1 -type d -name "*-*" 2>/dev/null | grep -v -E '^\\.(bin|lib|sbin|usr|var|etc|root|home|proc|sys|dev|tmp|run|boot|media|mnt|opt|srv)' | grep -v '\\.usr-is-merged' | head -n1)
    if [[ -z \"\$source_dir\" ]]; then
      # Fallback: use ls and grep to find non-system directories
      source_dir=\$(ls -d */ 2>/dev/null | grep -v -E '^(bin|lib|sbin|usr|var|etc|root|home|proc|sys|dev|tmp|run|boot|media|mnt|opt|srv).*/' | head -n1 | sed 's|/$||')
      if [[ -n \"\$source_dir\" ]]; then
        source_dir=\"./\$source_dir\"
      fi
    fi
    if [[ -z \"\$source_dir\" ]]; then
      echo \"ERROR: No source directory found after apt-get source ${pkg}\"
      exit 1
    fi
    echo \"Found source directory: \$source_dir\"
    cd \"\$source_dir\"
    dpkg-buildpackage -us -uc -b -j${BUILD_PARALLEL}
  " 2>&1 | tee "$LOGDIR/20_build_${pkg}.log"

  # Normal cleanup (trap will also handle emergency cleanup)
  cleanup_mounts

  # Clear trap after successful cleanup
  trap - INT TERM EXIT

  # Collect built packages
  mkdir -p "$OUTDIR/$pkg"
  find "$BUILDER_WORK" -maxdepth 1 -type f -name '*.deb' -exec cp {} "$OUTDIR/$pkg/" \;
  
  local deb_count
  deb_count=$(find "$OUTDIR/$pkg" -name '*.deb' | wc -l)
  if [[ $deb_count -eq 0 ]]; then
    err "No .deb packages found for $pkg - build may have failed"
    return 1
  fi
  
  # Calculate and display build time
  local build_end_time=$(date +%s)
  local build_duration=$((build_end_time - build_start_time))
  local hours=$((build_duration / 3600))
  local minutes=$(((build_duration % 3600) / 60))
  local seconds=$((build_duration % 60))
  
  msg "Build completed successfully: $pkg ($deb_count packages created)"
  msg "Build duration: ${hours}h ${minutes}m ${seconds}s (total: ${build_duration}s)"
  find "$OUTDIR/$pkg" -name '*.deb' | sed 's/^/  /'
}

install_to_target() {
  local pkg="$1"
  
  # Check if package is already installed (unless forced)
  if [[ "${FORCE_REBUILD:-0}" != "1" && -f "$LOGDIR/30_install_${pkg}.log" ]]; then
    msg "Package already installed: $pkg (found install log)"
    msg "To reinstall, use FORCE_REBUILD=1 or remove $LOGDIR/30_install_${pkg}.log"
    return 0
  fi
  
  msg "Installing built package into target: $pkg"
  
  mkdir -p "$TARGET_ROOTFS/host-out"
  mount --bind "$OUTDIR/$pkg" "$TARGET_ROOTFS/host-out"
  
  # ensure qemu-static present
  cp /usr/bin/qemu-riscv64-static "$TARGET_ROOTFS/usr/bin/" || true
  
  chroot "$TARGET_ROOTFS" bash -lc "
    set -e
    dpkg -i /host-out/*.deb || apt-get -f -y install
  " 2>&1 | tee "$LOGDIR/30_install_${pkg}.log"
  
  umount "$TARGET_ROOTFS/host-out"
  msg "Package installed successfully: $pkg"
}

record_build_info() {
  local pkg="$1"
  msg "Recording build information for: $pkg"
  
  mkdir -p "$BUILD_ROOT_DIR/records"
  
  # Record package versions and configuration
  for root in "$TARGET_ROOTFS" "$BUILDER_WORK"; do
    [[ -d "$root" ]] || continue
    local tag; tag=$(basename "$root")
    chroot "$root" bash -lc "apt-cache policy" > "$BUILD_ROOT_DIR/records/${tag}_apt-cache-policy.txt" 2>/dev/null || true
    chroot "$root" bash -lc "dpkg -l" > "$BUILD_ROOT_DIR/records/${tag}_dpkg-l.txt" 2>/dev/null || true
    cp "$root/etc/apt/sources.list" "$BUILD_ROOT_DIR/records/${tag}_sources.list" 2>/dev/null || true
  done
  
  # Record build metadata
  cat > "$BUILD_ROOT_DIR/records/build_info_${pkg}.txt" <<EOF
Package: $pkg
Build Date: $(date)
Build Host: $(uname -a)
Build PID: $$
Build Parallel: $BUILD_PARALLEL
Architecture: $ARCH
Suite: $SUITE
Mirror: $MIRROR
Build Root: $BUILD_ROOT_DIR
EOF
}

main() {
  need_sudo
  validate_pkg_name "$PACKAGE"
  
  msg "Starting single package build"
  msg "Package: $PACKAGE"
  msg "Build Root: $BUILD_ROOT_DIR"
  msg "Parallel Jobs: $BUILD_PARALLEL"
  
  # Setup global cleanup trap
  trap 'cleanup_mounts; err "Build interrupted - cleaning up mounts"; exit 1' INT TERM
  
  prepare_dirs
  ensure_host_deps
  make_target_rootfs
  make_builder_base
  build_package "$PACKAGE"
  install_to_target "$PACKAGE"
  record_build_info "$PACKAGE"
  
  msg "Single package build completed successfully: $PACKAGE"
  msg "Output directory: $OUTDIR/$PACKAGE"
  msg "Log directory: $LOGDIR"
  msg "Build records: $BUILD_ROOT_DIR/records"
}

main "$@"