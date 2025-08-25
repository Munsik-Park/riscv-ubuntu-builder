#!/usr/bin/env bash
# create_boot_script.sh
# Create U-Boot boot script for automatic booting
# Usage: sudo ./create_boot_script.sh

set -euo pipefail

# ------------ Config ------------
BASE_DIR="${BASE_DIR:-/srv/qemu-base}"
BASE_IMG_NAME="ubuntu-riscv-base.qcow2"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

create_uboot_boot_script() {
  msg "Creating U-Boot auto-boot script..."
  
  # Create boot.scr source
  local boot_script_src="/tmp/boot.cmd"
  cat > "$boot_script_src" << 'EOF'
# U-Boot auto-boot script for Ubuntu RISC-V
echo "Loading Ubuntu RISC-V kernel..."

# Set boot arguments
setenv bootargs "root=/dev/vda1 rw rootwait console=ttyS0,115200 earlycon=sbi init=/sbin/init"

# Scan for virtio devices
virtio scan

# Load kernel and initrd
echo "Loading kernel from /boot/vmlinuz-6.14.0-28-generic..."
ext4load virtio 0:1 0x84000000 /boot/vmlinuz-6.14.0-28-generic

echo "Skipping initrd due to format issues..."
# ext4load virtio 0:1 0x88000000 /boot/initrd.img-6.14.0-28-generic

echo "Booting kernel..."
booti 0x84000000 - ${fdtcontroladdr}
EOF

  # Compile boot script
  msg "Compiling boot script..."
  if command -v mkimage >/dev/null 2>&1; then
    mkimage -C none -A riscv -T script -d "$boot_script_src" /tmp/boot.scr.uimg
    msg "Boot script compiled to /tmp/boot.scr.uimg"
  else
    err "mkimage not found, installing u-boot-tools..."
    apt-get update && apt-get install -y u-boot-tools
    mkimage -C none -A riscv -T script -d "$boot_script_src" /tmp/boot.scr.uimg
  fi
  
  rm "$boot_script_src"
}

install_boot_script_to_image() {
  msg "Installing boot script to base image..."
  
  # Convert qcow2 to raw for mounting
  local raw_image="/tmp/base-raw-$$.img"
  qemu-img convert -f qcow2 -O raw "$BASE_DIR/$BASE_IMG_NAME" "$raw_image"
  
  # Setup loop device
  local loop_device
  loop_device=$(losetup --find --show "$raw_image")
  partprobe "$loop_device"
  sleep 1
  
  # Mount the partition
  local mount_point="/tmp/boot-mount-$$"
  mkdir -p "$mount_point"
  mount "${loop_device}p1" "$mount_point"
  
  # Install boot script to /boot
  msg "Copying boot script to /boot directory..."
  cp /tmp/boot.scr.uimg "$mount_point/boot/boot.scr.uimg"
  cp /tmp/boot.scr.uimg "$mount_point/boot.scr.uimg"  # U-Boot looks for both
  
  # Also create a simple boot.scr (without .uimg extension)
  cp /tmp/boot.scr.uimg "$mount_point/boot.scr"
  
  # Set proper permissions
  chmod 644 "$mount_point"/boot/boot.*
  
  # Sync and cleanup
  sync
  umount "$mount_point"
  rmdir "$mount_point"
  losetup -d "$loop_device"
  
  # Convert back to qcow2
  msg "Converting image back to qcow2..."
  qemu-img convert -f raw -O qcow2 "$raw_image" "$BASE_DIR/$BASE_IMG_NAME.new"
  mv "$BASE_DIR/$BASE_IMG_NAME.new" "$BASE_DIR/$BASE_IMG_NAME"
  rm "$raw_image"
  
  # Cleanup temp files
  rm -f /tmp/boot.scr.uimg
  
  msg "Boot script installed successfully"
}

verify_installation() {
  msg "Verifying boot script installation..."
  
  # Convert and mount to verify
  local raw_image="/tmp/verify-$$.img"
  qemu-img convert -f qcow2 -O raw "$BASE_DIR/$BASE_IMG_NAME" "$raw_image"
  
  local loop_device
  loop_device=$(losetup --find --show "$raw_image")
  partprobe "$loop_device"
  sleep 1
  
  local mount_point="/tmp/verify-mount-$$"
  mkdir -p "$mount_point"
  mount "${loop_device}p1" "$mount_point"
  
  msg "Boot files in /boot:"
  ls -la "$mount_point/boot/" | grep -E "(boot|scr)" || echo "No boot script files found"
  
  # Check if files exist
  if [[ -f "$mount_point/boot/boot.scr.uimg" ]]; then
    msg "✅ boot.scr.uimg found"
  else
    warn "❌ boot.scr.uimg missing"
  fi
  
  if [[ -f "$mount_point/boot.scr.uimg" ]]; then
    msg "✅ boot.scr.uimg (alternative location) found"
  else
    warn "❌ boot.scr.uimg (alternative location) missing"
  fi
  
  # Cleanup
  umount "$mount_point"
  rmdir "$mount_point" 
  losetup -d "$loop_device"
  rm "$raw_image"
  
  msg "Verification completed"
}

# ------------ Main Process ------------
need_sudo

if [[ ! -f "$BASE_DIR/$BASE_IMG_NAME" ]]; then
  err "Base image not found: $BASE_DIR/$BASE_IMG_NAME"
  err "Please run build_base_image.sh first"
  exit 1
fi

msg "Creating U-Boot auto-boot configuration..."
msg "Base image: $BASE_DIR/$BASE_IMG_NAME"

# Create and install boot script
create_uboot_boot_script
install_boot_script_to_image
verify_installation

msg "========================================="
msg "U-Boot auto-boot script installed!"
msg "========================================="
msg ""
msg "The base image now contains:"
msg "  - /boot/boot.scr.uimg (U-Boot script)"
msg "  - /boot.scr.uimg (alternative location)"
msg "  - /boot.scr (fallback)"
msg ""
msg "Boot process will now be automatic:"
msg "  1. U-Boot loads boot.scr.uimg"
msg "  2. Script scans virtio devices"
msg "  3. Loads kernel from /boot"
msg "  4. Boots Ubuntu automatically"
msg ""
msg "Test with: sudo ./test_base_image.sh"
msg "========================================="