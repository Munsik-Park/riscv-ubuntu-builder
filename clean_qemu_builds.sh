#!/usr/bin/env bash
# clean_qemu_builds.sh
# Clean up QEMU build environments and processes
# Usage: sudo ./clean_qemu_builds.sh [package_name|all]

set -euo pipefail

QEMU_BASE_DIR="${QEMU_BASE_DIR:-/srv/qemu-builds}"
PACKAGE_NAME="${1:-}"

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
Usage: $0 [package_name|all]

Clean up QEMU build environments and processes.

Arguments:
  package_name    Clean specific package (e.g., tar, binutils)
  all            Clean all QEMU builds (default)

Examples:
  $0              # Clean all QEMU builds
  $0 all          # Clean all QEMU builds
  $0 tar          # Clean only tar build
  $0 binutils     # Clean only binutils build

Safety:
  - Kills running build processes
  - Unmounts chroot filesystems
  - Removes build directories
  - Shows what will be cleaned before execution
EOF
}

is_safe_to_kill_qemu_process() {
    local pid="$1"
    local cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
    local root=$(sudo readlink "/proc/$pid/root" 2>/dev/null || echo "/")
    
    # Skip critical system processes
    if [[ "$cmdline" =~ (systemd|kernel|kthread) ]]; then
        return 1  # Not safe
    fi
    
    # Skip VSCode processes
    if [[ "$cmdline" =~ (vscode-server|code-server|command-shell) ]]; then
        return 1  # Not safe
    fi
    
    # Skip other user applications on host root
    if [[ "$cmdline" =~ (ssh|bash|zsh|nano|vim|emacs|git) && "$root" == "/" ]]; then
        return 1  # Not safe
    fi
    
    # Only kill QEMU build processes
    if [[ "$cmdline" =~ build_qemu_single\.sh ]]; then
        return 0  # Safe to kill
    fi
    
    # Kill chroot processes related to QEMU builds
    if [[ "$root" =~ /srv/qemu-builds/.*/target-rootfs$ || "$root" =~ /srv/qemu-builds/.*/builder-base$ ]]; then
        if [[ "$cmdline" =~ (dpkg-buildpackage|gcc|make|chroot) ]]; then
            return 0  # Safe to kill
        fi
    fi
    
    return 1  # Not safe by default
}

kill_build_processes() {
    local target_pkg="${1:-}"
    
    local pids safe_pids=()
    
    if [[ -n "$target_pkg" ]]; then
        msg "Safely killing QEMU build processes for package: $target_pkg"
        pids=$(pgrep -f "build_qemu_single.sh $target_pkg" 2>/dev/null || true)
    else
        msg "Safely killing all QEMU build processes"
        pids=$(pgrep -f "build_qemu_single.sh" 2>/dev/null || true)
    fi
    
    # Filter to only safe-to-kill processes
    if [[ -n "$pids" ]]; then
        while IFS= read -r pid; do
            if [[ -n "$pid" ]] && is_safe_to_kill_qemu_process "$pid"; then
                safe_pids+=("$pid")
            elif [[ -n "$pid" ]]; then
                local cmd=$(ps -p "$pid" -o cmd --no-headers 2>/dev/null | cut -c1-50)
                warn "Skipping non-QEMU process: PID $pid ($cmd...)"
            fi
        done <<< "$pids"
    fi
    
    if [[ ${#safe_pids[@]} -eq 0 ]]; then
        msg "No QEMU build processes found to terminate"
        return 0
    fi
    
    # Step 1: Send TERM signal
    for pid in "${safe_pids[@]}"; do
        local cmd=$(ps -p "$pid" -o cmd --no-headers 2>/dev/null | cut -c1-50)
        msg "Sending TERM signal to QEMU PID: $pid ($cmd...)"
        kill -TERM "$pid" 2>/dev/null || true
    done
    
    # Step 2: Wait for graceful termination
    msg "Waiting for QEMU processes to terminate gracefully..."
    sleep 5
    
    # Step 3: Check for remaining and force kill if necessary
    local remaining_pids=()
    for pid in "${safe_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            remaining_pids+=("$pid")
        fi
    done
    
    if [[ ${#remaining_pids[@]} -gt 0 ]]; then
        msg "Force killing remaining QEMU processes..."
        for pid in "${remaining_pids[@]}"; do
            local cmd=$(ps -p "$pid" -o cmd --no-headers 2>/dev/null | cut -c1-50)
            msg "Force killing QEMU PID: $pid ($cmd...)"
            kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 2
    fi
    
    msg "QEMU process cleanup completed"
}

detect_devtmpfs_mount() {
  local mount_point="$1"
  local fstype
  fstype=$(findmnt -n -o FSTYPE "$mount_point" 2>/dev/null || true)
  
  if [[ "$fstype" == "devtmpfs" ]]; then
    return 0  # Is devtmpfs
  else
    return 1  # Not devtmpfs
  fi
}

detect_dangerous_bind_mount() {
  local mount_point="$1"
  local mount_info
  mount_info=$(findmnt -n -o TARGET,SOURCE "$mount_point" 2>/dev/null || true)
  
  if [[ -n "$mount_info" ]]; then
    local target source
    target=$(echo "$mount_info" | awk '{print $1}')
    source=$(echo "$mount_info" | awk '{print $2}')
    
    # Detect bind mounts to critical host directories
    if [[ "$source" =~ ^/(dev|proc|sys|boot|etc)$ ]]; then
      err "CRITICAL: Detected bind mount from host critical directory!"
      err "  Mount Point: $target"
      err "  Source: $source"
      err "  This could contaminate the host system!"
      return 1
    fi
  fi
  
  return 0
}

safe_umount() {
  local mount_point="$1"
  local max_retries="${2:-3}"
  
  # CRITICAL: Check for devtmpfs first - NEVER force umount devtmpfs!
  if detect_devtmpfs_mount "$mount_point"; then
    warn "Detected devtmpfs mount: $mount_point"
    msg "Using ONLY lazy umount for devtmpfs safety..."
    if umount -l "$mount_point" 2>/dev/null; then
      msg "Successfully lazy unmounted devtmpfs: $mount_point"
      return 0
    else
      warn "Lazy umount may have detached devtmpfs: $mount_point"
      return 0  # Always succeed for devtmpfs - lazy umount is safe
    fi
  fi
  
  # SAFETY CHECK: Handle dangerous bind mounts automatically
  if ! detect_dangerous_bind_mount "$mount_point"; then
    warn "Detected dangerous bind mount: $mount_point"
    msg "Using lazy umount for safety..."
    if umount -l "$mount_point" 2>/dev/null; then
      msg "Successfully lazy unmounted dangerous bind mount: $mount_point"
      return 0
    else
      warn "Lazy umount failed, mount may still be active but detached"
      return 0  # Don't fail - lazy umount detaches even if processes use it
    fi
  fi
  
  # Check if still mounted
  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    return 0
  fi
  
  # Attempt normal umount first
  if umount "$mount_point" 2>/dev/null; then
    msg "Successfully unmounted: $mount_point"
    return 0
  fi
  
  warn "Normal umount failed for $mount_point, trying lazy umount..."
  if umount -l "$mount_point" 2>/dev/null; then
    msg "Successfully lazy unmounted: $mount_point"
    return 0
  fi
  
  # NEVER use force umount - it can crash the system with devtmpfs
  warn "Lazy umount failed for $mount_point, skipping dangerous force umount..."
  warn "Mount point may remain detached but system is safe"
  return 0  # Don't fail - safety over completeness
}

cleanup_mounts() {
    local build_dir="$1"
    
    if [[ ! -d "$build_dir" ]]; then
        return 0
    fi
    
    warn "Safely cleaning up mounts in: $build_dir"
    
    # Find all mount points in the build directory, sorted by depth (deepest first)
    local mount_points
    mount_points=$(mount | grep "$build_dir" | awk '{print $3}' | sort -r || true)
    
    if [[ -n "$mount_points" ]]; then
        while IFS= read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
                msg "Processing mount point: $mount_point"
                safe_umount "$mount_point"
            fi
        done <<< "$mount_points"
        
        # Give system time to settle
        sleep 1
        msg "Mount cleanup completed for: $build_dir"
    else
        # Fallback: check common mount points
        for mount_point in \
            "$build_dir/target-rootfs/proc" \
            "$build_dir/target-rootfs/sys" \
            "$build_dir/target-rootfs/dev/pts" \
            "$build_dir/target-rootfs/dev" \
            "$build_dir/builder-base/proc" \
            "$build_dir/builder-base/sys" \
            "$build_dir/builder-base/dev/pts" \
            "$build_dir/builder-base/dev"
        do
            if mountpoint -q "$mount_point" 2>/dev/null; then
                msg "Processing common mount point: $mount_point"
                safe_umount "$mount_point"
            fi
        done
    fi
}

remove_build_directory() {
    local build_dir="$1"
    
    if [[ ! -d "$build_dir" ]]; then
        return 0
    fi
    
    msg "Removing build directory: $build_dir"
    
    # First try normal removal
    if rm -rf "$build_dir" 2>/dev/null; then
        return 0
    fi
    
    # If that fails, try with force
    warn "Normal removal failed, trying with force..."
    rm -rf "$build_dir" 2>/dev/null || true
    
    # Check if anything remains
    if [[ -d "$build_dir" ]]; then
        err "Failed to completely remove: $build_dir"
        ls -la "$build_dir" 2>/dev/null || true
        return 1
    fi
}

show_cleanup_preview() {
    local target_pkg="${1:-}"
    
    echo "========================================"
    echo "QEMU Build Cleanup Preview"
    echo "========================================"
    
    if [[ -n "$target_pkg" ]]; then
        echo "Target package: $target_pkg"
        echo "Build directory: $QEMU_BASE_DIR/$target_pkg"
    else
        echo "Target: ALL QEMU builds"
        echo "Base directory: $QEMU_BASE_DIR"
    fi
    
    echo
    echo "Active QEMU processes:"
    if [[ -n "$target_pkg" ]]; then
        if pgrep -f "build_qemu_single.sh $target_pkg" >/dev/null; then
            pgrep -f "build_qemu_single.sh $target_pkg" | while read pid; do
                local cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null | cut -c1-60)
                echo "  PID $pid: $cmd..."
            done
        else
            echo "  No active processes for $target_pkg"
        fi
    else
        if pgrep -f "build_qemu_single.sh" >/dev/null; then
            pgrep -f "build_qemu_single.sh" | while read pid; do
                local cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null | cut -c1-60)
                echo "  PID $pid: $cmd..."
            done
        else
            echo "  No active QEMU build processes"
        fi
    fi
    
    echo
    echo "Build directories to remove:"
    if [[ -n "$target_pkg" ]]; then
        local build_dir="$QEMU_BASE_DIR/$target_pkg"
        if [[ -d "$build_dir" ]]; then
            local size=$(du -sh "$build_dir" 2>/dev/null | cut -f1)
            echo "  $build_dir ($size)"
        else
            echo "  No build directory for $target_pkg"
        fi
    else
        if [[ -d "$QEMU_BASE_DIR" ]]; then
            for build_dir in "$QEMU_BASE_DIR"/*; do
                if [[ -d "$build_dir" ]]; then
                    local pkg=$(basename "$build_dir")
                    local size=$(du -sh "$build_dir" 2>/dev/null | cut -f1)
                    echo "  $build_dir ($size)"
                fi
            done
        else
            echo "  No QEMU build directories found"
        fi
    fi
    echo "========================================"
}

clean_package() {
    local pkg_name="$1"
    local build_dir="$QEMU_BASE_DIR/$pkg_name"
    
    msg "Cleaning QEMU build for package: $pkg_name"
    
    # Kill processes
    kill_build_processes "$pkg_name"
    
    # Wait a moment for processes to die
    sleep 1
    
    # Clean up mounts
    cleanup_mounts "$build_dir"
    
    # Remove directory
    if remove_build_directory "$build_dir"; then
        msg "✅ Successfully cleaned: $pkg_name"
    else
        err "❌ Failed to fully clean: $pkg_name"
        return 1
    fi
}

clean_all() {
    msg "Cleaning all QEMU builds"
    
    # Kill all processes first
    kill_build_processes
    
    # Wait for processes to die
    sleep 2
    
    if [[ ! -d "$QEMU_BASE_DIR" ]]; then
        msg "No QEMU build directory found: $QEMU_BASE_DIR"
        return 0
    fi
    
    local failed_cleanups=()
    
    # Clean each package
    for build_dir in "$QEMU_BASE_DIR"/*; do
        if [[ -d "$build_dir" ]]; then
            local pkg_name=$(basename "$build_dir")
            
            cleanup_mounts "$build_dir"
            
            if remove_build_directory "$build_dir"; then
                msg "✅ Cleaned: $pkg_name"
            else
                err "❌ Failed to clean: $pkg_name"
                failed_cleanups+=("$pkg_name")
            fi
        fi
    done
    
    # Try to remove the base directory if empty
    rmdir "$QEMU_BASE_DIR" 2>/dev/null || true
    
    if [[ ${#failed_cleanups[@]} -eq 0 ]]; then
        msg "✅ All QEMU builds cleaned successfully"
    else
        err "❌ Failed to clean some packages: ${failed_cleanups[*]}"
        return 1
    fi
}

# ------------ Main Logic ------------

case "${PACKAGE_NAME:-all}" in
    -h|--help|help)
        show_usage
        exit 0
        ;;
    all|"")
        need_sudo
        show_cleanup_preview
        echo
        read -p "Proceed with cleanup? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            clean_all
        else
            msg "Cleanup cancelled"
        fi
        ;;
    *)
        need_sudo
        show_cleanup_preview "$PACKAGE_NAME"
        echo
        read -p "Proceed with cleanup for $PACKAGE_NAME? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            clean_package "$PACKAGE_NAME"
        else
            msg "Cleanup cancelled"
        fi
        ;;
esac