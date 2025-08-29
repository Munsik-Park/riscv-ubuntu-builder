#!/usr/bin/env bash
# create_package_snapshot.sh
# Create package-specific snapshot from base image
# Usage: sudo ./create_package_snapshot.sh <package_name>

set -euo pipefail

PACKAGE_NAME="${1:-}"
if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package_name>"
    echo "Example: $0 tar"
    exit 1
fi

# ------------ Config ------------
BASE_DIR="${BASE_DIR:-/srv/qemu-base}"
SNAPSHOTS_DIR="${SNAPSHOTS_DIR:-/srv/qemu-snapshots}"
VM_DIR="$SNAPSHOTS_DIR/$PACKAGE_NAME"
LOGDIR="$VM_DIR/logs"

# Base image info (using official Ubuntu image)
BASE_IMG="$BASE_DIR/ubuntu-riscv-base-official.qcow2"
KERNEL_FILE="/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf"
UBOOT_FILE="/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf"

# Package-specific image
PKG_IMG_NAME="ubuntu-${PACKAGE_NAME}.qcow2"

# SSH Configuration
SSH_PORT_BASE=2222
SSH_PORT=$((SSH_PORT_BASE + $(echo "$PACKAGE_NAME" | cksum | cut -d' ' -f1) % 1000))

# VM Configuration (High Performance)
VM_MEMORY="${VM_MEMORY:-65536}"  # 64GB memory for build performance
VM_CPUS="${VM_CPUS:-4}"          # 4 CPUs for parallel builds

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

check_base_image() {
  if [[ ! -f "$BASE_IMG" ]]; then
    err "Base image not found: $BASE_IMG"
    err "Please run: sudo ./build_base_image.sh first"
    exit 1
  fi
  
  if [[ ! -f "$KERNEL_FILE" ]]; then
    err "Kernel file not found: $KERNEL_FILE"
    err "Please run: sudo ./build_base_image.sh first"
    exit 1
  fi
}

create_snapshot() {
  if [[ -f "$VM_DIR/$PKG_IMG_NAME" ]]; then
    msg "Package snapshot already exists: $VM_DIR/$PKG_IMG_NAME"
    return 0
  fi
  
  msg "Creating snapshot for package: $PACKAGE_NAME"
  mkdir -p "$VM_DIR" "$LOGDIR"
  
  # Create snapshot using QCOW2 backing file
  qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$VM_DIR/$PKG_IMG_NAME"
  
  msg "Package snapshot created: $VM_DIR/$PKG_IMG_NAME"
}

install_package_dependencies() {
  if [[ -f "$VM_DIR/.deps_installed" ]]; then
    msg "Package dependencies already installed for $PACKAGE_NAME"
    return 0
  fi
  
  msg "Installing build dependencies for $PACKAGE_NAME..."
  
  # Start VM to install dependencies
  local vm_pid
  msg "Starting QEMU VM with SSH port $SSH_PORT..."
  qemu-system-riscv64 \
    -machine virt \
    -m "$VM_MEMORY" \
    -smp "$VM_CPUS" \
    -kernel "/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf" \
    -drive "file=$VM_DIR/$PKG_IMG_NAME,format=qcow2,if=virtio" \
    -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" \
    -device "virtio-net-device,netdev=net0" \
    -device "virtio-rng-pci" \
    -display none \
    -daemonize \
    -pidfile "$VM_DIR/vm.pid" \
    -monitor "unix:$VM_DIR/monitor.sock,server,nowait" \
    2> "$LOGDIR/qemu.log"
  
  vm_pid=$(cat "$VM_DIR/vm.pid")
  msg "VM started with PID: $vm_pid, SSH port: $SSH_PORT"
  
  # Verify VM process is running
  if ! kill -0 "$vm_pid" 2>/dev/null; then
    err "VM process failed to start or died immediately"
    if [[ -f "$LOGDIR/qemu.log" ]]; then
      err "QEMU error log:"
      cat "$LOGDIR/qemu.log" >&2
    fi
    exit 1
  fi
  
  # Wait for VM to boot and SSH to be available
  msg "Waiting for VM to boot (this may take 2-3 minutes for RISC-V)..."
  sleep 60  # Longer initial wait for RISC-V boot
  
  local retries=120  # Much longer wait (10 minutes total)
  while [[ $retries -gt 0 ]]; do
    # Check if VM process is still alive
    if ! kill -0 "$vm_pid" 2>/dev/null; then
      err "VM process died unexpectedly"
      exit 1
    fi
    
    # Try SSH connection
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /srv/ssh-keys/builder_key -p "$SSH_PORT" builder@localhost 'echo "VM ready"' 2>/dev/null; then
      msg "SSH connection established successfully"
      break
    fi
    
    sleep 5
    retries=$((retries - 1))
    if (( retries % 20 == 0 )); then
      msg "Still waiting for SSH... ($retries retries left, ~$((retries * 5 / 60)) minutes remaining)"
      msg "VM process PID $vm_pid is still running"
    fi
  done
  
  if [[ $retries -eq 0 ]]; then
    err "Failed to connect to VM via SSH"
    kill "$vm_pid" 2>/dev/null || true
    exit 1
  fi
  
  # Install package-specific dependencies
  msg "Installing build dependencies via SSH..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /srv/ssh-keys/builder_key -p "$SSH_PORT" builder@localhost bash <<EOSSH || true
set -e

# Update package lists
sudo apt-get update

# Try to install build dependencies for the specific package
echo "Installing build dependencies for: $PACKAGE_NAME"
if sudo apt-get build-dep -y "$PACKAGE_NAME" 2>&1 | tee /tmp/build-dep.log; then
    echo "Build dependencies installed successfully"
else
    echo "Warning: Some build dependencies may not be available"
    echo "Installing common build tools instead..."
    sudo apt-get install -y \
        autotools-dev automake autoconf pkg-config libtool gettext \
        bison flex gawk 2>/dev/null || true
fi

# Clean up to reduce snapshot size
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
rm -f /tmp/build-dep.log

# Mark dependencies as installed
touch /home/builder/.deps_installed

EOSSH
  
  # Shutdown VM gracefully
  msg "Shutting down VM..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /srv/ssh-keys/builder_key -p "$SSH_PORT" builder@localhost 'sudo shutdown -h now' || true
  
  # Wait for VM to shutdown
  local shutdown_wait=30
  while [[ $shutdown_wait -gt 0 ]] && kill -0 "$vm_pid" 2>/dev/null; do
    sleep 2
    shutdown_wait=$((shutdown_wait - 1))
  done
  
  # Force kill if still running
  if kill -0 "$vm_pid" 2>/dev/null; then
    warn "Force killing VM"
    kill -9 "$vm_pid"
  fi
  
  rm -f "$VM_DIR/vm.pid"
  
  touch "$VM_DIR/.deps_installed"
  msg "Package dependencies installation completed"
}

generate_vm_config() {
  msg "Generating VM configuration for $PACKAGE_NAME..."
  
  cat > "$VM_DIR/vm-config.json" <<EOF
{
  "package": "$PACKAGE_NAME",
  "image": "$PKG_IMG_NAME",
  "base_image": "ubuntu-riscv-base.qcow2",
  "kernel": "fw_jump.elf",
  "memory": $VM_MEMORY,
  "cpus": $VM_CPUS,
  "ssh_port": $SSH_PORT,
  "created": "$(date -Iseconds)"
}
EOF

  # Copy kernel files for convenience
  cp "$KERNEL_FILE" "$VM_DIR/"
  [[ -f "$UBOOT_FILE" ]] && cp "$UBOOT_FILE" "$VM_DIR/"

  cat > "$VM_DIR/start-vm.sh" <<EOF
#!/bin/bash
# Auto-generated VM startup script for $PACKAGE_NAME

VM_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$VM_DIR"

echo "Starting VM for package: $PACKAGE_NAME"
echo "SSH port: $SSH_PORT"
echo "VM directory: \$VM_DIR"

# Use recommended QEMU configuration for Ubuntu 24.04 RISC-V
qemu-system-riscv64 \\
  -machine virt \\
  -m $VM_MEMORY \\
  -smp $VM_CPUS \\
  -kernel "/usr/lib/u-boot/qemu-riscv64_smode/uboot.elf" \\
  -drive file=$PKG_IMG_NAME,format=qcow2,if=virtio \\
  -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \\
  -device virtio-net-device,netdev=net0 \\
  -device virtio-rng-pci \\
  -nographic \\
  "\$@"
EOF

  chmod +x "$VM_DIR/start-vm.sh"
  
  msg "VM configuration saved to: $VM_DIR/vm-config.json"
  msg "VM startup script: $VM_DIR/start-vm.sh"
}

# ------------ Main Process ------------
need_sudo

msg "Creating package snapshot for: $PACKAGE_NAME"
msg "VM directory: $VM_DIR"
msg "SSH port: $SSH_PORT"

# Check if base image exists
check_base_image

# Step 1: Create snapshot from base image
create_snapshot

# Step 2: Install package-specific dependencies
install_package_dependencies

# Step 3: Generate configuration
generate_vm_config

msg "=================================="
msg "Package snapshot completed!"
msg "Package: $PACKAGE_NAME"  
msg "VM directory: $VM_DIR"
msg "Image file: $VM_DIR/$PKG_IMG_NAME"
msg "SSH port: $SSH_PORT"
msg ""
msg "To start the VM:"
msg "  $VM_DIR/start-vm.sh"
msg ""
msg "To connect via SSH:"
msg "  ssh -i /srv/ssh-keys/builder_key -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null builder@localhost"
msg "=================================="