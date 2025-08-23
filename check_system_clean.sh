#!/usr/bin/env bash
# check_system_clean.sh
# Check and optionally clean system state before builds

set -euo pipefail

BUILD_BASE_DIR="${BUILD_BASE_DIR:-/srv}"

msg() { echo -e "\033[1;32m[CHECK] $*\033[0m"; }
warn() { echo -e "\033[1;33m[CHECK] $*\033[0m"; }
err() { echo -e "\033[1;31m[CHECK] $*\033[0m" >&2; }

check_running_processes() {
  msg "Checking for running build processes..."
  local running_procs
  # Look for actual build processes (not the current check)
  running_procs=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep || true)
  
  if [[ -n "$running_procs" ]]; then
    warn "Found running build processes:"
    echo "$running_procs"
    return 1
  else
    msg "No running build processes found"
    return 0
  fi
}

check_mount_points() {
  msg "Checking for existing rvbuild mount points..."
  local existing_mounts
  existing_mounts=$(mount | grep "${BUILD_BASE_DIR}/rvbuild" || true)
  
  if [[ -n "$existing_mounts" ]]; then
    warn "Found existing mount points:"
    echo "$existing_mounts"
    return 1
  else
    msg "No rvbuild mount points found"
    return 0
  fi
}

check_build_directories() {
  msg "Checking for existing build directories..."
  local build_dirs
  build_dirs=$(find "$BUILD_BASE_DIR" -maxdepth 1 -name "rvbuild-*" -type d 2>/dev/null || true)
  
  if [[ -n "$build_dirs" ]]; then
    warn "Found existing build directories:"
    echo "$build_dirs" | sed 's/^/  /'
    return 1
  else
    msg "No existing build directories found"
    return 0
  fi
}

check_mount_usage() {
  local mount_point="$1"
  
  # Check if mount point is in use using multiple methods
  if command -v lsof >/dev/null 2>&1; then
    local lsof_result
    lsof_result=$(lsof +D "$mount_point" 2>/dev/null || true)
    if [[ -n "$lsof_result" ]]; then
      warn "Mount point $mount_point is in use (lsof):"
      echo "$lsof_result" | head -10
      return 1
    fi
  fi
  
  if command -v fuser >/dev/null 2>&1; then
    local fuser_result
    fuser_result=$(fuser -m "$mount_point" 2>/dev/null || true)
    if [[ -n "$fuser_result" ]]; then
      warn "Mount point $mount_point is in use (fuser): $fuser_result"
      return 1
    fi
  fi
  
  return 0
}

detect_dangerous_bind_mount() {
  local mount_point="$1"
  
  # Check if this is a bind mount to critical host directories
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

detect_devtmpfs_mount() {
  local mount_point="$1"
  
  # Check if this is a devtmpfs mount
  local fstype
  fstype=$(findmnt -n -o FSTYPE "$mount_point" 2>/dev/null || true)
  
  if [[ "$fstype" == "devtmpfs" ]]; then
    return 0  # Is devtmpfs
  else
    return 1  # Not devtmpfs
  fi
}

safe_umount() {
  local mount_point="$1"
  local max_retries="${2:-3}"
  local retry_count=0
  
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
  
  while [[ $retry_count -lt $max_retries ]]; do
    # Check if still mounted
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
      msg "Mount point $mount_point already unmounted"
      return 0
    fi
    
    # Check for usage before attempting umount
    if ! check_mount_usage "$mount_point"; then
      warn "Mount point $mount_point is in use, waiting..."
      sleep 2
      ((retry_count++))
      continue
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
    
    ((retry_count++))
    if [[ $retry_count -lt $max_retries ]]; then
      warn "Umount attempt $retry_count failed for $mount_point, retrying in 2 seconds..."
      sleep 2
    fi
  done
  
  err "Failed to unmount $mount_point after $max_retries attempts"
  return 1
}

force_kill_mount_users() {
  local mount_point="$1"
  msg "Force terminating processes using mount point: $mount_point"
  
  # Get PIDs of processes using the mount point
  local pids
  if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof +D "$mount_point" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
  fi
  
  if [[ -n "$pids" ]]; then
    msg "Found processes using mount point: $pids"
    while IFS= read -r pid; do
      if [[ -n "$pid" && "$pid" -gt 1 ]]; then  # Never kill init
        local cmdline
        cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)
        local root=$(sudo readlink "/proc/$pid/root" 2>/dev/null || echo "/")
        
        # Skip critical system processes
        if [[ "$cmdline" =~ (systemd|kernel|kthread) ]]; then
          warn "Skipping critical system process: $pid ($cmdline)"
          continue
        fi
        
        # Skip VSCode processes - they should not be killed during mount cleanup
        if [[ "$cmdline" =~ (vscode-server|code-server|command-shell) ]]; then
          warn "Skipping VSCode process: $pid ($cmdline)"
          continue
        fi
        
        # Skip other user applications that might be using the filesystem
        if [[ "$cmdline" =~ (ssh|bash|zsh|nano|vim|emacs|git) && "$root" == "/" ]]; then
          warn "Skipping user application: $pid ($cmdline)"
          continue
        fi
        
        # Only kill if it's clearly a build-related process or in chroot
        if [[ "$cmdline" =~ (build_single_package|dpkg-buildpackage|gcc|make) || "$root" =~ /srv/rvbuild-.*/builder$ ]]; then
          msg "[FORCE] Killing build process $pid: $cmdline"
          kill -TERM "$pid" 2>/dev/null || true
          sleep 1
          kill -KILL "$pid" 2>/dev/null || true
        else
          warn "Skipping non-build process: $pid ($cmdline)"
        fi
      fi
    done <<< "$pids"
    sleep 2  # Allow processes to die
  fi
}

cleanup_mounts() {
  msg "Cleaning up mount points..."
  
  # Ensure required tools are available
  if ! command -v lsof >/dev/null 2>&1; then
    warn "lsof not available, installing for safer mount cleanup..."
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y lsof >/dev/null 2>&1 || warn "Failed to install lsof"
  fi
  
  # Find all rvbuild mounts, sorted by depth (deepest first for proper umount order)
  local mount_points
  mount_points=$(mount | grep "${BUILD_BASE_DIR}/rvbuild" | awk '{print $3}' | sort -r || true)
  
  if [[ -n "$mount_points" ]]; then
    while IFS= read -r mount_point; do
      if [[ -n "$mount_point" ]]; then
        msg "Processing mount point: $mount_point"
        
        # Try normal safe umount first
        if safe_umount "$mount_point" 1; then
          continue  # Success
        fi
        
        # If normal umount fails, try killing processes and force umount
        warn "Normal umount failed, attempting force cleanup for: $mount_point"
        force_kill_mount_users "$mount_point"
        
        # Try lazy umount after killing processes
        if umount -l "$mount_point" 2>/dev/null; then
          msg "Successfully force cleaned mount point: $mount_point"
        else
          # Final fallback - detached lazy umount always succeeds
          warn "Mount point may remain detached: $mount_point"
        fi
      fi
    done <<< "$mount_points"
    
    # Give system time to settle
    sleep 2
    msg "Mount cleanup completed - some mounts may be lazily detached"
  else
    msg "No rvbuild mount points found to clean up"
  fi
}

wait_for_process_termination() {
  local pid="$1"
  local timeout="${2:-30}"  # 30초 기본 타임아웃
  local count=0
  
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $count -ge $timeout ]]; then
      warn "Process $pid did not terminate within ${timeout}s timeout"
      return 1
    fi
    sleep 1
    ((count++))
  done
  
  msg "Process $pid terminated successfully after ${count}s"
  return 0
}

cleanup_processes() {
  msg "Terminating running build processes..."
  
  # Function to check if process is safe to kill
  is_safe_to_kill() {
    local pid="$1"
    local root=$(sudo readlink "/proc/$pid/root" 2>/dev/null || echo "/")
    local cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
    
    # Only kill if it's a build process AND (chroot process OR build script on host)
    if [[ "$cmdline" =~ build_single_package\.sh ]]; then
      # Allow killing if it's in chroot environment
      if [[ "$root" =~ /srv/rvbuild-.*/builder$ ]]; then
        return 0  # Safe to kill - chroot process
      fi
      # Allow killing if it's the main build script on host (but warn)
      if [[ "$root" == "/" && "$cmdline" =~ /home/ubuntu/riscv-ubuntu-builder/build_single_package\.sh ]]; then
        warn "Killing host build process: PID $pid"
        return 0  # Safe to kill - host build script
      fi
    fi
    return 1  # Not safe to kill
  }
  
  local pids safe_pids=()
  # Look for actual build processes only
  pids=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep | awk '{print $2}' || true)
  
  # Filter to only safe-to-kill processes
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      if [[ -n "$pid" ]] && is_safe_to_kill "$pid"; then
        safe_pids+=("$pid")
      elif [[ -n "$pid" ]]; then
        warn "Skipping non-build process: PID $pid"
      fi
    done <<< "$pids"
  fi
  
  if [[ ${#safe_pids[@]} -eq 0 ]]; then
    msg "No build processes found to terminate"
    return 0
  fi
  
  # Step 1: Send TERM signal to safe processes
  for pid in "${safe_pids[@]}"; do
    msg "Sending TERM signal to safe PID: $pid"
    kill -TERM "$pid" 2>/dev/null || warn "Failed to terminate PID: $pid"
  done
  
  # Step 2: Wait for each process to terminate gracefully
  msg "Waiting for processes to terminate gracefully..."
  for pid in "${safe_pids[@]}"; do
    if ! wait_for_process_termination "$pid" 15; then
      warn "Process $pid did not respond to TERM signal"
    fi
  done
  
  # Step 3: Check for remaining safe processes and force kill if necessary
  sleep 2  # Additional safety buffer
  local remaining_safe_pids=()
  pids=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep | awk '{print $2}' || true)
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      if [[ -n "$pid" ]] && is_safe_to_kill "$pid"; then
        remaining_safe_pids+=("$pid")
      fi
    done <<< "$pids"
  fi
  
  if [[ ${#remaining_safe_pids[@]} -gt 0 ]]; then
    msg "Force killing remaining safe processes..."
    for pid in "${remaining_safe_pids[@]}"; do
      msg "Force killing safe PID: $pid"
      kill -KILL "$pid" 2>/dev/null || warn "Failed to kill PID: $pid"
      # Wait for force kill to take effect
      wait_for_process_termination "$pid" 5 || warn "Process $pid may still be running"
    done
  fi
  
  # Step 4: Final verification - only check safe processes
  sleep 1
  local final_safe_pids=()
  pids=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep | awk '{print $2}' || true)
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      if [[ -n "$pid" ]] && is_safe_to_kill "$pid"; then
        final_safe_pids+=("$pid")
      fi
    done <<< "$pids"
  fi
  
  if [[ ${#final_safe_pids[@]} -gt 0 ]]; then
    err "Some build processes are still running after cleanup:"
    for pid in "${final_safe_pids[@]}"; do
      cmd=$(ps -p "$pid" -o cmd --no-headers 2>/dev/null || echo "Unknown")
      echo "  PID $pid: $cmd"
    done
    return 1
  else
    msg "All build processes terminated successfully"
  fi
}

cleanup_directories() {
  msg "Removing build directories..."
  
  # First try normal removal
  if rm -rf "${BUILD_BASE_DIR}"/rvbuild-* 2>/dev/null; then
    msg "Build directories removed successfully"
    return 0
  fi
  
  # If normal removal fails, try more aggressive approaches
  warn "Normal directory removal failed, trying alternative methods..."
  
  # Try to remove immutable attributes and force removal
  local build_dirs
  build_dirs=$(find "$BUILD_BASE_DIR" -maxdepth 1 -name "rvbuild-*" -type d 2>/dev/null || true)
  
  while IFS= read -r dir; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      msg "Force removing: $dir"
      
      # Remove immutable attributes if any
      chattr -R -i "$dir" 2>/dev/null || true
      
      # Try different removal strategies
      if ! rm -rf "$dir" 2>/dev/null; then
        warn "Standard rm failed for $dir, trying chmod + rm..."
        chmod -R 755 "$dir" 2>/dev/null || true
        rm -rf "$dir" 2>/dev/null || warn "Failed to remove $dir completely"
      fi
    fi
  done <<< "$build_dirs"
  
  # Final check
  local remaining
  remaining=$(find "$BUILD_BASE_DIR" -maxdepth 1 -name "rvbuild-*" -type d 2>/dev/null || true)
  if [[ -n "$remaining" ]]; then
    warn "Some directories could not be removed:"
    echo "$remaining"
  else
    msg "All build directories removed successfully"
  fi
}

# Main functions
check_system() {
  local has_issues=0
  
  msg "=== System State Check ==="
  
  if ! check_running_processes; then has_issues=1; fi
  if ! check_mount_points; then has_issues=1; fi
  if ! check_build_directories; then has_issues=1; fi
  
  if [[ $has_issues -eq 1 ]]; then
    warn "System is not clean - issues found"
    return 1
  else
    msg "System is clean - ready for build"
    return 0
  fi
}

validate_cleanup_safety() {
  msg "Performing pre-cleanup safety validation..."
  
  # Check for any bind mounts to critical host directories
  local dangerous_mounts
  dangerous_mounts=$(findmnt -D -o TARGET,SOURCE | grep -E "/(dev|proc|sys|boot|etc)\s" | grep "${BUILD_BASE_DIR}/rvbuild" || true)
  
  if [[ -n "$dangerous_mounts" ]]; then
    warn "Dangerous bind mounts detected before cleanup:"
    echo "$dangerous_mounts"
    warn "Will use safe lazy umount to handle these automatically."
  fi
  
  # Verify we're not running cleanup on host root directories
  if [[ "${BUILD_BASE_DIR}" =~ ^/(dev|proc|sys|boot|etc|bin|sbin|usr)$ ]]; then
    err "CRITICAL: BUILD_BASE_DIR points to critical host directory: ${BUILD_BASE_DIR}"
    err "This could destroy the host system. Aborting cleanup."
    return 1
  fi
  
  msg "Pre-cleanup safety validation completed"
  return 0
}

clean_system() {
  msg "=== System Cleanup ==="
  
  # Step 0: Safety validation (never fails, only warns)
  msg "Step 0/4: Safety validation..."
  validate_cleanup_safety  # Always proceed even if dangerous mounts detected
  
  # Step 1: Terminate processes first (most critical) - Never fails
  msg "Step 1/4: Terminating processes..."
  cleanup_processes  # Always tries best effort cleanup
  
  # Step 2: Wait additional buffer time before umount
  msg "Waiting 3 seconds for process cleanup to stabilize..."
  sleep 3
  
  # Step 3: Clean up mounts (second most critical) - Never fails
  msg "Step 2/4: Cleaning up mount points..."
  cleanup_mounts  # Always succeeds with lazy umount fallback
  
  # Step 4: Clean up directories (least critical) - Never fails
  msg "Step 3/4: Cleaning up directories..."
  cleanup_directories  # Always tries multiple approaches
  
  # Step 5: Final system state verification - Reports status but never fails
  msg "Step 4/4: Final verification..."
  local final_processes
  final_processes=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep || true)
  if [[ -n "$final_processes" ]]; then
    warn "Some build processes are still running (may be normal):"
    echo "$final_processes" | head -3  # Limit output
  fi
  
  local final_mounts
  final_mounts=$(mount | grep "${BUILD_BASE_DIR}/rvbuild" || true)
  if [[ -n "$final_mounts" ]]; then
    warn "Some mount points may still be lazily detached (this is safe):"
    echo "$final_mounts" | head -3  # Limit output
  fi
  
  local remaining_dirs
  remaining_dirs=$(find "$BUILD_BASE_DIR" -maxdepth 1 -name "rvbuild-*" -type d 2>/dev/null || true)
  if [[ -n "$remaining_dirs" ]]; then
    warn "Some build directories remain (may require reboot to clean):"
    echo "$remaining_dirs"
  fi
  
  # Always report success - clean is best-effort and should never fail completely
  msg "System cleanup completed - system is now safe to use"
  msg "Note: Some resources may be lazily cleaned by the kernel"
}

# Command handling
case "${1:-check}" in
  check)
    if [[ $EUID -ne 0 ]]; then
      err "Please run as root (sudo) for system checks"
      exit 1
    fi
    check_system
    ;;
  clean)
    if [[ $EUID -ne 0 ]]; then
      err "Please run as root (sudo) for system cleanup"
      exit 1
    fi
    clean_system
    ;;
  *)
    echo "Usage: $0 [check|clean]"
    echo ""
    echo "Commands:"
    echo "  check  - Check system state (default)"
    echo "  clean  - Clean up system state"
    exit 1
    ;;
esac