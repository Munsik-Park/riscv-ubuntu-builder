#!/usr/bin/env bash
# build_base_image.sh
# Create a common base QEMU VM image with build dependencies
# Usage: sudo ./build_base_image.sh

set -euo pipefail

# ------------ Config ------------
SUITE="${SUITE:-noble}"
ARCH="${ARCH:-riscv64}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
BASE_DIR="${BASE_DIR:-/srv/qemu-base}"
ROOTFS_DIR="$BASE_DIR/rootfs"
LOGDIR="$BASE_DIR/logs"

# VM Configuration
VM_DISK_SIZE="${VM_DISK_SIZE:-8G}"

# Image and kernel paths
BASE_IMG_NAME="ubuntu-riscv-base.qcow2"
KERNEL_FILE="$BASE_DIR/fw_jump.elf"
UBOOT_FILE="$BASE_DIR/uboot.elf"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  
  # Cleanup any temporary mounts
  for mp in "$ROOTFS_DIR"/{proc,sys,dev/pts,dev}; do
    if mountpoint -q "$mp" 2>/dev/null; then
      warn "Cleaning up mount: $mp"
      umount -l "$mp" 2>/dev/null || true
    fi
  done
  
  if [[ $exit_code -ne 0 ]]; then
    err "Base image build failed"
  else
    msg "Base image build completed"
  fi
}

trap cleanup_on_exit EXIT

install_host_dependencies() {
  msg "Installing host dependencies..."
  
  local packages=(
    "qemu-system-misc"
    "qemu-utils" 
    "debootstrap"
    "binfmt-support"
    "qemu-user-static"
  )
  
  for pkg in "${packages[@]}"; do
    if ! dpkg -l "$pkg" >/dev/null 2>&1; then
      msg "Installing $pkg..."
      apt-get update >/dev/null 2>&1
      apt-get install -y "$pkg"
    fi
  done
}

download_kernel() {
  mkdir -p "$(dirname "$KERNEL_FILE")"
  
  if [[ -f "$KERNEL_FILE" && -f "$UBOOT_FILE" ]]; then
    msg "Using existing kernel files: $KERNEL_FILE, $UBOOT_FILE"
    return 0
  fi
  
  msg "Installing RISC-V firmware packages..."
  apt-get update >/dev/null 2>&1
  apt-get install -y opensbi u-boot-qemu
  
  if [[ -f "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.elf" ]]; then
    cp "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.elf" "$KERNEL_FILE"
    msg "Copied OpenSBI firmware: $KERNEL_FILE"
  elif [[ -f "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin" ]]; then
    cp "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin" "$KERNEL_FILE"
    msg "Copied OpenSBI firmware (binary): $KERNEL_FILE"
  else
    err "OpenSBI firmware not found after package installation"
    exit 1
  fi
  
  if [[ -f "/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf" ]]; then
    cp "/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf" "$UBOOT_FILE"
    msg "Copied U-Boot: $UBOOT_FILE"
  elif [[ -f "/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin" ]]; then
    cp "/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin" "$UBOOT_FILE"
    msg "Copied U-Boot (binary): $UBOOT_FILE"
  else
    warn "U-Boot not found, will use modern QEMU boot method"
    rm -f "$UBOOT_FILE"
  fi
}

create_base_rootfs() {
  if [[ -f "$BASE_DIR/.base_ready" ]]; then
    msg "Base rootfs already exists"
    return 0
  fi
  
  msg "Creating base Ubuntu rootfs..."
  mkdir -p "$ROOTFS_DIR" "$LOGDIR"
  
  # Create base rootfs with essential packages only
  local essential_packages="systemd,dbus,openssh-server,sudo,wget,curl,ca-certificates,gnupg"
  local basic_build="build-essential,dpkg-dev,debhelper,git,vim,nano"
  local basic_network="iputils-ping,iproute2,netbase"
  
  # Use minimal debootstrap with retries and error handling
  local retry_count=0
  local max_retries=3
  
  while [[ $retry_count -lt $max_retries ]]; do
    msg "Debootstrap attempt $((retry_count + 1))/$max_retries"
    
    # Clean any previous failed attempt
    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"
    
    # Try minimal debootstrap first
    if debootstrap --arch="$ARCH" \
       --variant=minbase \
       --foreign \
       "$SUITE" "$ROOTFS_DIR" "$MIRROR" \
       2>&1 | tee "$LOGDIR/01_debootstrap_attempt_$((retry_count + 1)).log"; then
      
      # Second stage
      if DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage \
         2>&1 | tee "$LOGDIR/02_debootstrap_stage2_attempt_$((retry_count + 1)).log"; then
        msg "Debootstrap completed successfully"
        break
      fi
    fi
    
    retry_count=$((retry_count + 1))
    if [[ $retry_count -lt $max_retries ]]; then
      warn "Debootstrap failed, retrying in 10 seconds..."
      sleep 10
    fi
  done
  
  if [[ $retry_count -eq $max_retries ]]; then
    err "Debootstrap failed after $max_retries attempts"
    exit 1
  fi
  
  # Mount necessary filesystems for chroot
  msg "Setting up chroot environment..."
  mount -t proc proc "$ROOTFS_DIR/proc"
  mount -t sysfs sysfs "$ROOTFS_DIR/sys"
  mount -t devtmpfs devtmpfs "$ROOTFS_DIR/dev"
  mount -t devpts devpts "$ROOTFS_DIR/dev/pts"
  
  # Setup DNS for package downloads (fix broken systemd-resolved symlink in chroot)
  # Remove systemd-resolved symlink and create proper nameserver configuration
  rm -f "$ROOTFS_DIR/etc/resolv.conf"
  cat > "$ROOTFS_DIR/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
  
  # Configure base system
  msg "Configuring base VM system..."
  
  chroot "$ROOTFS_DIR" /bin/bash <<'EOCHROOT'
set -e

# Set password
echo 'root:root' | chpasswd

# Create build user
useradd -m -s /bin/bash -G sudo builder
echo 'builder:builder' | chpasswd

# Enable services (if systemctl is available)
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable ssh || echo "Warning: Could not enable ssh service"
    systemctl enable systemd-networkd || echo "Warning: Could not enable networkd"
    systemctl enable systemd-resolved || echo "Warning: Could not enable resolved"
else
    echo "Warning: systemctl not available, using alternative method"
    # Create symlinks manually for essential services
    ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service 2>/dev/null || true
    ln -sf /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true
    ln -sf /lib/systemd/system/systemd-resolved.service /etc/systemd/system/multi-user.target.wants/systemd-resolved.service 2>/dev/null || true
fi

# Set hostname
echo 'ubuntu-riscv-base' > /etc/hostname

# Configure network (DHCP for all interfaces)
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-dhcp.network << 'EOF'
[Match]
Name=eth* en*

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=1.1.1.1
EOF

# Ensure networkd starts the interface
cat > /etc/systemd/network/20-virtio.network << 'EOF'
[Match]
Driver=virtio_net

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=1.1.1.1
LinkLocalAddressing=ipv4
EOF

# Configure DNS fallback
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8
DNS=1.1.1.1
FallbackDNS=8.8.4.4
Domains=~
DNSSEC=no
DNSOverTLS=no
EOF

# Setup resolv.conf for DNS resolution
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Add fallback DNS servers
echo "nameserver 8.8.8.8" > /etc/resolv.conf.fallback
echo "nameserver 1.1.1.1" >> /etc/resolv.conf.fallback

# Configure SSH
mkdir -p /home/builder/.ssh /etc/ssh/sshd_config.d
chmod 700 /home/builder/.ssh

# Copy SSH public key from host (if exists)
if [[ -f "/srv/ssh-keys/builder_key.pub" ]]; then
    cp "/srv/ssh-keys/builder_key.pub" /home/builder/.ssh/authorized_keys
    chmod 600 /home/builder/.ssh/authorized_keys
    chown builder:builder /home/builder/.ssh/authorized_keys
    echo "SSH key installed for builder user"
fi

cat > /etc/ssh/sshd_config.d/99-vm-build.conf << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
EOF

# Configure sudo
mkdir -p /etc/sudoers.d
echo 'builder ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/builder

# Configure GRUB for automatic boot (3 second timeout)
cat >> /etc/default/grub << 'EOF'
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_DEFAULT=0
GRUB_RECORDFAIL_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
EOF

# Update GRUB configuration
if command -v update-grub >/dev/null 2>&1; then
    update-grub || echo "Warning: Could not update GRUB configuration"
else
    echo "Warning: update-grub not available, GRUB may need manual configuration"
fi

# Add source repositories for build-dep (modern .sources format)
cat > /etc/apt/sources.list.d/ubuntu.sources << 'EOF'
Types: deb deb-src
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-security noble-backports
Components: main restricted universe multiverse
EOF

# Verify DNS resolution works
echo "Testing DNS resolution..."
nslookup ports.ubuntu.com || echo "Warning: DNS resolution may be problematic"

# Update package lists and upgrade system
apt-get update
apt-get upgrade -y

# Install systemd and essential packages first
apt-get install -y systemd systemd-sysv dbus openssh-server sudo wget curl ca-certificates gnupg

# Install kernel and bootloader for RISC-V
echo "Installing kernel packages for RISC-V..."
apt-get install -y linux-image-generic linux-headers-generic || echo "Warning: Generic kernel may not support RISC-V"

# Try RISC-V specific packages
apt-get install -y linux-image-riscv64 linux-headers-riscv64 2>/dev/null || echo "RISC-V specific kernel not available"

# Install GRUB packages
apt-get install -y grub-common grub2-common grub-efi-riscv64 || apt-get install -y grub-pc || echo "Warning: GRUB installation may fail"

# Verify kernel installation
echo "Checking installed kernels..."
ls -la /boot/ || echo "No boot directory found"
ls -la /lib/modules/ || echo "No modules directory found"

# Install build essentials
apt-get install -y build-essential dpkg-dev debhelper git vim nano

# Install network tools and utilities
apt-get install -y iputils-ping iproute2 netbase net-tools dhcpcd-base isc-dhcp-client

# Install additional network utilities
apt-get install -y \
  dnsutils \
  telnet \
  wget \
  curl \
  netcat-openbsd \
  traceroute \
  iptables \
  2>/dev/null || echo "Warning: Some network utilities may not be available"

# Install additional development tools (best effort)
apt-get install -y \
  autotools-dev automake autoconf pkg-config libtool gettext \
  bison flex gawk net-tools htop lsof strace gdb file less rsync \
  cmake \
  python3-dev python3-setuptools \
  2>/dev/null || echo "Warning: Some packages may not be available for RISC-V"

# Install development libraries (best effort)  
apt-get install -y \
  libssl-dev libxml2-dev libxslt1-dev \
  zlib1g-dev libbz2-dev liblzma-dev \
  libffi-dev libreadline-dev libsqlite3-dev \
  2>/dev/null || echo "Warning: Some dev libraries may not be available for RISC-V"

# Create directories for build artifacts
mkdir -p /home/builder/{build,output,logs}
chown -R builder:builder /home/builder/{build,output,logs}

# Set up environment for builder user
cat >> /home/builder/.bashrc << 'EOF'

# Build environment setup
export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS="parallel=1 reproducible=+all"

# Helpful aliases
alias ll='ls -la'
alias la='ls -la'
alias l='ls -l'
alias ..='cd ..'
alias grep='grep --color=auto'

# Build functions
build-package() {
    local pkg="$1"
    if [[ -z "$pkg" ]]; then
        echo "Usage: build-package <package-name>"
        return 1
    fi
    
    cd /home/builder/build
    echo "Building package: $pkg"
    
    # Download source
    apt-get source "$pkg"
    
    # Find source directory
    local src_dir=$(find . -maxdepth 1 -type d -name "${pkg}-*" | head -n1)
    if [[ -z "$src_dir" ]]; then
        echo "Error: Source directory not found"
        return 1
    fi
    
    cd "$src_dir"
    
    # Build package
    dpkg-buildpackage -us -uc -b -j1
    
    # Copy results
    cd ..
    cp *.deb /home/builder/output/ 2>/dev/null || echo "No .deb files generated"
    
    echo "Build completed. Results in /home/builder/output/"
}

EOF

EOCHROOT

  # Install GRUB to disk image (outside chroot, after disk creation)
  if [[ -f "$ROOTFS_DIR/usr/sbin/grub-install" ]]; then
    msg "Installing GRUB bootloader..."
    # Create a temporary device mapping for GRUB installation
    echo "GRUB installation will be done during disk image creation"
  fi

  # Copy SSH key from host to VM (outside chroot)
  if [[ -f "/srv/ssh-keys/builder_key.pub" ]]; then
    msg "Installing SSH key for builder user..."
    mkdir -p "$ROOTFS_DIR/home/builder/.ssh"
    cp "/srv/ssh-keys/builder_key.pub" "$ROOTFS_DIR/home/builder/.ssh/authorized_keys"
    chmod 700 "$ROOTFS_DIR/home/builder/.ssh"
    chmod 600 "$ROOTFS_DIR/home/builder/.ssh/authorized_keys"
    chown -R 1000:1000 "$ROOTFS_DIR/home/builder/.ssh"  # builder user UID:GID
  else
    warn "SSH key not found: /srv/ssh-keys/builder_key.pub"
    warn "SSH key authentication may not work"
  fi
  
  # Cleanup mounts
  umount "$ROOTFS_DIR/dev/pts"
  umount "$ROOTFS_DIR/dev"
  umount "$ROOTFS_DIR/sys"
  umount "$ROOTFS_DIR/proc"
  
  touch "$BASE_DIR/.base_ready"
  msg "Base rootfs configuration completed"
}

create_base_disk_image() {
  if [[ -f "$BASE_DIR/$BASE_IMG_NAME" ]]; then
    msg "Base disk image already exists: $BASE_DIR/$BASE_IMG_NAME"
    return 0
  fi
  
  msg "Creating base disk image..."
  
  # Create raw image first (qcow2 cannot be directly loop mounted)
  local raw_image="/tmp/ubuntu-riscv-base-$$.raw"
  truncate -s "$VM_DISK_SIZE" "$raw_image"
  
  # Format and mount raw image
  local loop_device
  loop_device=$(losetup --find --show "$raw_image")
  
  # Create partition table and filesystem
  parted "$loop_device" --script mklabel gpt
  parted "$loop_device" --script mkpart primary ext4 1MiB 100%
  
  # Let kernel recognize the partition
  partprobe "$loop_device"
  sleep 1
  
  # Format the partition
  mkfs.ext4 -F "${loop_device}p1"
  
  # Mount and copy rootfs
  local mount_point="/tmp/base-mount-$$"
  mkdir -p "$mount_point"
  mount "${loop_device}p1" "$mount_point"
  
  msg "Copying base rootfs to disk image..."
  # Use tar to preserve all attributes and ensure complete copy
  (cd "$ROOTFS_DIR" && tar -cf - .) | (cd "$mount_point" && tar -xf -)
  
  # Verify critical directories were copied
  msg "Verifying critical directories..."
  ls -la "$mount_point/boot/" || echo "Warning: /boot directory missing"
  ls -la "$mount_point/lib/modules/" || echo "Warning: /lib/modules directory missing"
  
  # Install GRUB bootloader to disk
  msg "Installing GRUB bootloader to disk..."
  if [[ -f "$mount_point/usr/sbin/grub-install" ]]; then
    # Mount required filesystems for GRUB installation
    mount -t proc proc "$mount_point/proc"
    mount -t sysfs sysfs "$mount_point/sys"
    mount -t devtmpfs devtmpfs "$mount_point/dev"
    
    # Install GRUB using chroot
    chroot "$mount_point" /bin/bash -c "
      grub-install --target=i386-pc --boot-directory=/boot $loop_device
      update-grub
    " || echo "Warning: GRUB installation failed"
    
    # Cleanup mounts
    umount "$mount_point/dev" "$mount_point/sys" "$mount_point/proc" || true
  else
    warn "GRUB not found, skipping bootloader installation"
  fi
  
  sync
  
  # Cleanup
  umount "$mount_point"
  rmdir "$mount_point"
  losetup -d "$loop_device"
  
  # Convert raw to qcow2
  msg "Converting raw image to qcow2 format..."
  qemu-img convert -f raw -O qcow2 "$raw_image" "$BASE_DIR/$BASE_IMG_NAME"
  rm "$raw_image"
  
  msg "Base disk image created: $BASE_DIR/$BASE_IMG_NAME"
}

# ------------ Main Process ------------
need_sudo

msg "Building base VM image"
msg "Base directory: $BASE_DIR"

# Create working directory
mkdir -p "$BASE_DIR" "$LOGDIR"

# Step 1: Install host dependencies
install_host_dependencies

# Step 2: Download kernel
download_kernel

# Step 3: Create and configure base rootfs
create_base_rootfs

# Step 4: Create base disk image
create_base_disk_image

msg "=================================="
msg "Base VM image build completed!"
msg "Base directory: $BASE_DIR"
msg "Base image: $BASE_DIR/$BASE_IMG_NAME"
msg ""
msg "Use create_package_snapshot.sh to create package-specific VMs"
msg "=================================="