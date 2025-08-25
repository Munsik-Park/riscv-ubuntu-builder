#!/usr/bin/env bash
# clean_base_image_all.sh
# Complete cleanup for fresh base image build
# Usage: sudo ./clean_base_image_all.sh

set -euo pipefail

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

show_usage() {
    cat << EOF
Usage: $0

Complete cleanup for fresh RISC-V base image build.

This script will:
  1. Clean QEMU build processes and directories
  2. Remove base image and all related files
  3. Clean VM images and snapshots
  4. Safely remove old chroot build remnants
  5. Recreate clean directory structure
  6. Prepare system for fresh base image build

Safety:
  - Kills running build processes safely
  - Unmounts filesystems before removal
  - Preserves SSH keys for VM access
  - Creates clean directory structure

After running this script, execute:
  sudo ./build_base_image.sh
EOF
}

safe_umount() {
  local mount_point="$1"
  
  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    return 0
  fi
  
  msg "Unmounting: $mount_point"
  
  # Try normal umount first
  if umount "$mount_point" 2>/dev/null; then
    msg "Successfully unmounted: $mount_point"
    return 0
  fi
  
  # Try lazy umount
  warn "Normal umount failed, trying lazy umount for: $mount_point"
  if umount -l "$mount_point" 2>/dev/null; then
    msg "Successfully lazy unmounted: $mount_point"
    return 0
  fi
  
  warn "Failed to unmount $mount_point, but continuing for safety"
  return 0
}

cleanup_existing_qemu_builds() {
  msg "Step 1/6: Cleaning existing QEMU builds..."
  
  if [[ -f "./clean_qemu_builds.sh" ]]; then
    msg "Running existing QEMU cleanup script (auto-confirming)..."
    # Use printf to send 'y' and newline to auto-confirm the prompt
    printf "y\n" | ./clean_qemu_builds.sh all || {
      warn "QEMU cleanup script failed, continuing with manual cleanup"
      
      # Manual cleanup as fallback
      msg "Performing manual QEMU process cleanup..."
      pkill -f "build_qemu_single.sh" 2>/dev/null || true
      sleep 1
    }
  else
    warn "clean_qemu_builds.sh not found, performing manual QEMU cleanup"
  fi
  
  # Manual QEMU build cleanup
  if [[ -d "/srv/qemu-builds" ]]; then
    msg "Manually cleaning /srv/qemu-builds..."
    
    # Check for mount points first
    local mount_points
    mount_points=$(mount | grep "/srv/qemu-builds" | awk '{print $3}' | sort -r || true)
    
    if [[ -n "$mount_points" ]]; then
      warn "Found mount points in qemu-builds, unmounting..."
      while IFS= read -r mp; do
        [[ -n "$mp" ]] && safe_umount "$mp"
      done <<< "$mount_points"
    fi
    
    # Remove directories
    rm -rf /srv/qemu-builds/*
    msg "Cleaned /srv/qemu-builds"
  fi
}

cleanup_base_image() {
  msg "Step 2/6: Cleaning base image directory..."
  
  if [[ -d "/srv/qemu-base" ]]; then
    # Check for mount points in base image
    local mount_points
    mount_points=$(mount | grep "/srv/qemu-base" | awk '{print $3}' | sort -r || true)
    
    if [[ -n "$mount_points" ]]; then
      warn "Found mount points in qemu-base, unmounting..."
      while IFS= read -r mp; do
        [[ -n "$mp" ]] && safe_umount "$mp"
      done <<< "$mount_points"
    fi
    
    # Remove all base image contents
    rm -rf /srv/qemu-base/*
    
    # Remove .base_ready file specifically (it might be hidden)
    rm -f /srv/qemu-base/.base_ready
    msg "Cleaned base image directory and removed .base_ready marker"
  else
    msg "Base image directory does not exist"
  fi
}

cleanup_vm_data() {
  msg "Step 3/6: Cleaning VM images and snapshots..."
  
  # Clean VM images
  if [[ -d "/srv/qemu-vms" ]]; then
    msg "Cleaning VM images..."
    rm -rf /srv/qemu-vms/*
    msg "Cleaned VM images"
  fi
  
  # Clean snapshots
  if [[ -d "/srv/qemu-snapshots" ]]; then
    msg "Cleaning VM snapshots..."
    rm -rf /srv/qemu-snapshots/*
    msg "Cleaned VM snapshots"
  fi
}

cleanup_old_chroot() {
  msg "Step 4/6: Safely cleaning old chroot build remnants..."
  
  if [[ -d "/srv/rvbuild" ]]; then
    # Check for active mount points
    local mount_points
    mount_points=$(mount | grep "/srv/rvbuild" | awk '{print $3}' | sort -r || true)
    
    if [[ -n "$mount_points" ]]; then
      warn "Found active chroot mount points, unmounting safely..."
      while IFS= read -r mp; do
        [[ -n "$mp" ]] && safe_umount "$mp"
      done <<< "$mount_points"
      
      # Wait for unmounts to complete
      sleep 2
    fi
    
    # Check for common chroot mount points and unmount them
    for mp in \
      "/srv/rvbuild/builder/dev/pts" \
      "/srv/rvbuild/builder/dev" \
      "/srv/rvbuild/builder/sys" \
      "/srv/rvbuild/builder/proc" \
      "/srv/rvbuild/target-rootfs/dev/pts" \
      "/srv/rvbuild/target-rootfs/dev" \
      "/srv/rvbuild/target-rootfs/sys" \
      "/srv/rvbuild/target-rootfs/proc"
    do
      safe_umount "$mp"
    done
    
    # Final check and removal
    local remaining_mounts
    remaining_mounts=$(mount | grep "/srv/rvbuild" || true)
    
    if [[ -n "$remaining_mounts" ]]; then
      warn "Some mount points may still be active (lazy unmounted):"
      echo "$remaining_mounts"
      warn "Continuing with removal - lazy unmounts are safe"
    fi
    
    # Remove directory
    rm -rf /srv/rvbuild/*
    msg "Cleaned old chroot build remnants"
  else
    msg "No old chroot builds found"
  fi
}

kill_related_processes() {
  msg "Step 5/6: Checking for related build processes..."
  
  # Check for any build-related processes
  local build_procs
  build_procs=$(ps aux | grep -E "(build_.*\.sh|qemu-system|chroot)" | grep -v grep | grep -v "clean_base_image_all.sh" || true)
  
  if [[ -n "$build_procs" ]]; then
    warn "Found potentially related processes:"
    echo "$build_procs"
    warn "These processes were not automatically killed for safety"
    warn "Please manually review and terminate if needed"
  else
    msg "No related build processes found"
  fi
}

recreate_directory_structure() {
  msg "Step 6/6: Recreating clean directory structure..."
  
  # Create base directories
  mkdir -p /srv/qemu-base/{logs,rootfs}
  mkdir -p /srv/qemu-builds
  mkdir -p /srv/qemu-vms  
  mkdir -p /srv/qemu-snapshots
  
  # Preserve SSH keys directory
  mkdir -p /srv/ssh-keys
  
  # Set proper permissions
  chmod 755 /srv/qemu-base /srv/qemu-builds /srv/qemu-vms /srv/qemu-snapshots
  chmod 755 /srv/qemu-base/logs /srv/qemu-base/rootfs
  
  msg "Directory structure recreated successfully"
}

check_disk_space() {
  msg "Checking available disk space..."
  
  local available_gb
  available_gb=$(df /srv | awk 'NR==2 {printf "%.1f", $4/1024/1024}')
  
  msg "Available space in /srv: ${available_gb}GB"
  
  if (( $(echo "$available_gb < 20.0" | bc -l) )); then
    warn "Low disk space detected. Base image build requires ~20GB minimum"
    warn "Consider freeing up space before proceeding"
  else
    msg "Sufficient disk space available"
  fi
}

verify_cleanup() {
  msg "Verifying cleanup completion..."
  
  # Check for remaining mount points
  local remaining_mounts
  remaining_mounts=$(mount | grep "/srv/" | grep -E "(qemu|rvbuild)" || true)
  
  if [[ -n "$remaining_mounts" ]]; then
    warn "Some mount points may still be active (this may be normal for lazy unmounts):"
    echo "$remaining_mounts"
  else
    msg "No active mount points found"
  fi
  
  # Check directory sizes
  msg "Final directory status:"
  du -sh /srv/qemu-* /srv/rvbuild 2>/dev/null | head -10 || true
  
  msg "Cleanup verification completed"
}

# ------------ Main Process ------------

# Handle command line arguments
case "${1:-}" in
  -h|--help|help)
    show_usage
    exit 0
    ;;
  *)
    # Continue with cleanup
    ;;
esac

need_sudo

msg "========================================"
msg "Complete Base Image Cleanup Starting"
msg "========================================"
msg "This will clean all QEMU build data and prepare for fresh base image build"
msg ""

# Warn user and get confirmation
warn "WARNING: This will remove all existing:"
warn "  - QEMU base images and build data"
warn "  - VM images and snapshots"  
warn "  - Old chroot build remnants"
warn ""
read -p "Continue with cleanup? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    msg "Cleanup cancelled by user"
    exit 0
fi

msg ""
msg "Starting complete cleanup process..."

# Execute cleanup steps
cleanup_existing_qemu_builds
cleanup_base_image
cleanup_vm_data
cleanup_old_chroot  
kill_related_processes
recreate_directory_structure

# Post-cleanup checks
check_disk_space
verify_cleanup

msg ""
msg "========================================"
msg "Complete Base Image Cleanup Finished!"
msg "========================================"
msg ""
msg "System is now ready for fresh base image build."
msg ""
msg "Next steps:"
msg "  1. Run: sudo ./build_base_image.sh"
msg "  2. Wait for base image build to complete"
msg "  3. Use create_package_snapshot.sh to create package-specific VMs"
msg ""
msg "Directory structure:"
msg "  /srv/qemu-base/     - Clean, ready for base image"
msg "  /srv/qemu-builds/   - Clean, ready for package builds"
msg "  /srv/qemu-vms/      - Clean, ready for VM images" 
msg "  /srv/qemu-snapshots/ - Clean, ready for snapshots"
msg "  /srv/ssh-keys/      - Preserved for VM access"
msg "========================================"