#!/usr/bin/env bash
# build_qemu_vm_image.sh
# Create bootable QEMU VM image with build dependencies for specific package
# Usage: sudo ./build_qemu_vm_image.sh <package_name>

set -euo pipefail

PACKAGE_NAME="${1:-}"
if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package_name>"
    echo "Example: $0 tar"
    exit 1
fi

# ------------ Config ------------
SUITE="${SUITE:-noble}"
ARCH="${ARCH:-riscv64}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
VM_BASE_DIR="${VM_BASE_DIR:-/srv/qemu-vms}"
VM_DIR="$VM_BASE_DIR/$PACKAGE_NAME"
ROOTFS_DIR="$VM_DIR/rootfs"
LOGDIR="$VM_DIR/logs"

# VM Configuration
VM_DISK_SIZE="${VM_DISK_SIZE:-8G}"
VM_MEMORY="${VM_MEMORY:-8192}"  # 8GB
VM_CPUS="${VM_CPUS:-1}"        # 1 CPU core

# Image and kernel paths
IMG_NAME="ubuntu-${PACKAGE_NAME}.qcow2"
KERNEL_FILE="$VM_DIR/fw_jump.elf"
UBOOT_FILE="$VM_DIR/uboot.elf"

# SSH Configuration
SSH_PORT_BASE=2222
SSH_PORT=$((SSH_PORT_BASE + $(echo "$PACKAGE_NAME" | cksum | cut -d' ' -f1) % 1000))

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
    err "VM image build failed for package: $PACKAGE_NAME"
  else
    msg "VM image build completed for package: $PACKAGE_NAME"
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
  
  # Check if we already have the necessary files
  if [[ -f "$KERNEL_FILE" && -f "$UBOOT_FILE" ]]; then
    msg "Using existing kernel files: $KERNEL_FILE, $UBOOT_FILE"
    return 0
  fi
  
  msg "Installing RISC-V firmware packages..."
  
  # Install required packages
  apt-get update >/dev/null 2>&1
  apt-get install -y opensbi u-boot-qemu
  
  # Copy firmware files
  if [[ -f "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.elf" ]]; then
    cp "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.elf" "$KERNEL_FILE"
    msg "Copied OpenSBI firmware: $KERNEL_FILE"
  elif [[ -f "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin" ]]; then
    cp "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin" "$KERNEL_FILE"
    msg "Copied OpenSBI firmware (binary): $KERNEL_FILE"
  else
    err "OpenSBI firmware not found after package installation"
    err "Expected location: /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.*"
    exit 1
  fi
  
  # Copy U-Boot
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

create_rootfs() {
  if [[ -f "$VM_DIR/.rootfs_ready" ]]; then
    msg "Rootfs already exists for $PACKAGE_NAME"
    return 0
  fi
  
  msg "Creating Ubuntu rootfs for $PACKAGE_NAME..."
  mkdir -p "$ROOTFS_DIR" "$LOGDIR"
  
  # Create base rootfs with essential packages only
  # Install additional packages later in chroot to avoid debootstrap issues
  local essential_packages="systemd,dbus,openssh-server,sudo,wget,curl,ca-certificates,gnupg"
  local basic_build="build-essential,dpkg-dev,debhelper,git,vim,nano"
  local basic_network="iputils-ping,iproute2,netbase"
  
  debootstrap --arch="$ARCH" \
    --include="$essential_packages,$basic_build,$basic_network" \
    "$SUITE" "$ROOTFS_DIR" "$MIRROR" \
    2>&1 | tee "$LOGDIR/01_debootstrap.log"
  
  # Configure system
  msg "Configuring VM system..."
  
  # Enable systemd services
  chroot "$ROOTFS_DIR" /bin/bash <<'EOCHROOT'
set -e

# Set password
echo 'root:root' | chpasswd

# Create build user
useradd -m -s /bin/bash -G sudo builder
echo 'builder:builder' | chpasswd

# Enable services
systemctl enable ssh
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Set hostname
echo 'ubuntu-riscv' > /etc/hostname

# Configure network (simple DHCP)
cat > /etc/systemd/network/10-dhcp.network << 'EOF'
[Match]
Name=en*

[Network]
DHCP=yes
EOF

# Configure SSH
mkdir -p /home/builder/.ssh
cat > /etc/ssh/sshd_config.d/99-vm-build.conf << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
EOF

# Configure sudo
echo 'builder ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/builder

# Update package lists and upgrade system
apt-get update
apt-get upgrade -y

# Install additional development tools
apt-get install -y \
  autotools-dev automake autoconf pkg-config libtool gettext texinfo \
  bison flex gawk net-tools htop tree lsof strace gdb file less rsync \
  cmake meson ninja-build \
  python3-dev python3-pip python3-setuptools \
  libssl-dev libxml2-dev libxslt1-dev \
  zlib1g-dev libbz2-dev liblzma-dev \
  libffi-dev libreadline-dev libsqlite3-dev \
  ccache distcc || echo "Warning: Some packages may not be available for RISC-V"

# Configure ccache for faster rebuilds
echo 'export PATH="/usr/lib/ccache:$PATH"' >> /etc/profile.d/ccache.sh

# Create directories for build artifacts
mkdir -p /home/builder/{build,output,logs}
chown -R builder:builder /home/builder/{build,output,logs}

# Set up environment for builder user
cat >> /home/builder/.bashrc << 'EOF'

# Build environment setup
export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS="parallel=1 reproducible=+all"
export CCACHE_DIR="/home/builder/.ccache"
export PATH="/usr/lib/ccache:$PATH"

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
  
  touch "$VM_DIR/.rootfs_ready"
  msg "Rootfs configuration completed"
}

install_build_dependencies() {
  if [[ -f "$VM_DIR/.deps_ready" ]]; then
    msg "Build dependencies already installed for $PACKAGE_NAME"
    return 0
  fi
  
  msg "Installing build dependencies for $PACKAGE_NAME..."
  
  # Install package-specific build dependencies
  chroot "$ROOTFS_DIR" /bin/bash <<EOCHROOT
set -e

# Update package lists
apt-get update

# Install build dependencies for the specific package
echo "Installing build dependencies for: $PACKAGE_NAME"
apt-get build-dep -y $PACKAGE_NAME || {
  echo "Warning: Some build dependencies may not be available"
  echo "Installing common build tools instead..."
  apt-get install -y build-essential autotools-dev automake autoconf \
    pkg-config libtool gettext texinfo bison flex gawk
}

# Install additional useful tools for debugging
apt-get install -y gdb strace ltrace lsof htop tree

# Clean up to reduce image size
apt-get clean
rm -rf /var/lib/apt/lists/*

EOCHROOT
  
  touch "$VM_DIR/.deps_ready"
  msg "Build dependencies installation completed"
}

create_disk_image() {
  if [[ -f "$VM_DIR/$IMG_NAME" ]]; then
    msg "Disk image already exists: $VM_DIR/$IMG_NAME"
    return 0
  fi
  
  msg "Creating disk image..."
  
  # Create qcow2 image
  qemu-img create -f qcow2 "$VM_DIR/$IMG_NAME" "$VM_DISK_SIZE"
  
  # Format and mount
  local loop_device
  loop_device=$(losetup --find --show "$VM_DIR/$IMG_NAME")
  
  # Create partition table and filesystem
  parted "$loop_device" --script mklabel gpt
  parted "$loop_device" --script mkpart primary ext4 1MiB 100%
  
  # Let kernel recognize the partition
  partprobe "$loop_device"
  sleep 1
  
  # Format the partition
  mkfs.ext4 -F "${loop_device}p1"
  
  # Mount and copy rootfs
  local mount_point="/tmp/vm-mount-$$"
  mkdir -p "$mount_point"
  mount "${loop_device}p1" "$mount_point"
  
  msg "Copying rootfs to disk image..."
  cp -a "$ROOTFS_DIR"/* "$mount_point/"
  
  # Install bootloader (if needed for RISC-V)
  sync
  
  # Cleanup
  umount "$mount_point"
  rmdir "$mount_point"
  losetup -d "$loop_device"
  
  msg "Disk image created: $VM_DIR/$IMG_NAME"
}

generate_vm_config() {
  msg "Generating VM configuration..."
  
  cat > "$VM_DIR/vm-config.json" <<EOF
{
  "package": "$PACKAGE_NAME",
  "image": "$IMG_NAME",
  "kernel": "fw_jump.elf",
  "memory": $VM_MEMORY,
  "cpus": $VM_CPUS,
  "ssh_port": $SSH_PORT,
  "disk_size": "$VM_DISK_SIZE",
  "created": "$(date -Iseconds)"
}
EOF

  cat > "$VM_DIR/start-vm.sh" <<EOF
#!/bin/bash
# Auto-generated VM startup script for $PACKAGE_NAME

VM_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$VM_DIR"

echo "Starting VM for package: $PACKAGE_NAME"
echo "SSH port: $SSH_PORT"
echo "VM directory: \$VM_DIR"

# Use modern QEMU approach if U-Boot is available, otherwise use legacy
if [[ -f "uboot.elf" ]]; then
  # Legacy boot with explicit OpenSBI and U-Boot
  qemu-system-riscv64 \\
    -machine virt -cpu rv64 \\
    -m $VM_MEMORY \\
    -smp $VM_CPUS \\
    -bios fw_jump.elf \\
    -kernel uboot.elf \\
    -append "root=/dev/vda1 rw console=ttyS0" \\
    -drive file=$IMG_NAME,format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \\
    -device virtio-net-device,netdev=net0 \\
    -device virtio-rng-pci \\
    -nographic \\
    "\$@"
else
  # Modern QEMU boot (7.0+) with automatic OpenSBI loading
  qemu-system-riscv64 \\
    -machine virt \\
    -m $VM_MEMORY \\
    -smp $VM_CPUS \\
    -drive file=$IMG_NAME,format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \\
    -device virtio-net-device,netdev=net0 \\
    -device virtio-rng-pci \\
    -nographic \\
    "\$@"
fi
EOF

  chmod +x "$VM_DIR/start-vm.sh"
  
  msg "VM configuration saved to: $VM_DIR/vm-config.json"
  msg "VM startup script: $VM_DIR/start-vm.sh"
}

# ------------ Main Process ------------
need_sudo

msg "Building VM image for package: $PACKAGE_NAME"
msg "VM directory: $VM_DIR"
msg "SSH port: $SSH_PORT"

# Create working directory
mkdir -p "$VM_DIR" "$LOGDIR"

# Step 1: Install host dependencies
install_host_dependencies

# Step 2: Download kernel
download_kernel

# Step 3: Create and configure rootfs
create_rootfs

# Step 4: Install build dependencies  
install_build_dependencies

# Step 5: Create disk image
create_disk_image

# Step 6: Generate configuration
generate_vm_config

msg "=================================="
msg "VM image build completed!"
msg "Package: $PACKAGE_NAME"  
msg "VM directory: $VM_DIR"
msg "Image file: $VM_DIR/$IMG_NAME"
msg "SSH port: $SSH_PORT"
msg ""
msg "To start the VM:"
msg "  $VM_DIR/start-vm.sh"
msg ""
msg "To connect via SSH:"
msg "  ssh -p $SSH_PORT root@localhost"
msg "  ssh -p $SSH_PORT builder@localhost"
msg "=================================="