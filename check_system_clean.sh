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

cleanup_mounts() {
  msg "Cleaning up mount points..."
  
  # Find and unmount all rvbuild mounts
  local mount_points
  mount_points=$(mount | grep "${BUILD_BASE_DIR}/rvbuild" | awk '{print $3}' || true)
  
  if [[ -n "$mount_points" ]]; then
    while IFS= read -r mount_point; do
      if [[ -n "$mount_point" ]]; then
        msg "Unmounting: $mount_point"
        umount "$mount_point" 2>/dev/null || warn "Failed to unmount: $mount_point"
      fi
    done <<< "$mount_points"
  fi
}

cleanup_processes() {
  msg "Terminating running build processes..."
  
  local pids
  # Look for actual build processes only
  pids=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep | awk '{print $2}' || true)
  
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      if [[ -n "$pid" ]]; then
        msg "Terminating PID: $pid"
        kill -TERM "$pid" 2>/dev/null || warn "Failed to terminate PID: $pid"
      fi
    done <<< "$pids"
    
    # Wait and force kill if necessary
    sleep 3
    pids=$(ps aux | grep -E "build_single_package\.sh" | grep -v grep | awk '{print $2}' || true)
    if [[ -n "$pids" ]]; then
      while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
          msg "Force killing PID: $pid"
          kill -KILL "$pid" 2>/dev/null || warn "Failed to kill PID: $pid"
        fi
      done <<< "$pids"
    fi
  fi
}

cleanup_directories() {
  msg "Removing build directories..."
  rm -rf "${BUILD_BASE_DIR}"/rvbuild-* || warn "Some directories could not be removed"
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

clean_system() {
  msg "=== System Cleanup ==="
  cleanup_processes
  cleanup_mounts
  cleanup_directories
  msg "System cleanup completed"
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