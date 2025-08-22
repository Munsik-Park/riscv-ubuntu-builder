#!/usr/bin/env bash
# build_parallel.sh
# Smart build script: parallel builds OR single package build
#
# Usage:
#   sudo bash build_parallel.sh clean                           # Clean up previous builds
#   sudo bash build_parallel.sh [max_parallel_jobs|package_name] # Run builds
#
# Examples:
#   sudo bash build_parallel.sh clean                # Clean up previous build processes and directories
#   sudo bash build_parallel.sh 4                    # Build all packages, 4 at a time
#   sudo bash build_parallel.sh bash                 # Build only bash package
#   sudo bash build_parallel.sh coreutils            # Build only coreutils package
#   BUILD_BASE_DIR=/custom sudo bash build_parallel.sh 2  # Use /custom/rvbuild-* directories
#
# Environment variables:
#   BUILD_BASE_DIR=/srv (base directory for all builds)
#
set -euo pipefail

# Default package list
#PACKAGES=(
#  bash coreutils grep sed findutils tar xz-utils 
#  util-linux iproute2 netbase ca-certificates iputils-ping
#  openssh-server binutils gdb
#)  binutils iputils-ping openssh-server  

# Default package list
PACKAGES=(
  coreutils tar 
)

# Parse argument: clean, number (parallel) or package name (single)
ARG1="${1:-2}"
BUILD_BASE_DIR="${BUILD_BASE_DIR:-/srv}"

# Check if argument is clean command, number, or package name
if [[ "$ARG1" == "clean" ]]; then
  # Clean mode
  BUILD_MODE="CLEAN"
elif [[ "$ARG1" =~ ^[0-9]+$ ]]; then
  # Number: parallel build mode
  MAX_PARALLEL="$ARG1"
  SINGLE_PACKAGE=""
  BUILD_MODE="PARALLEL"
else
  # String: single package mode
  MAX_PARALLEL=1
  SINGLE_PACKAGE="$ARG1"
  BUILD_MODE="SINGLE"
fi

msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] [$BUILD_MODE] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] [$BUILD_MODE] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] [$BUILD_MODE] $*\033[0m" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Please run as root (sudo)."
  exit 1
fi

# Handle clean mode
if [[ "$BUILD_MODE" == "CLEAN" ]]; then
  msg "Cleaning up system..."
  "$(dirname "$0")/check_system_clean.sh" clean
  msg "System cleanup completed."
  exit 0
fi

# Validate single package mode
if [[ "$BUILD_MODE" == "SINGLE" ]]; then
  if [[ ! " ${PACKAGES[*]} " =~ " $SINGLE_PACKAGE " ]]; then
    err "Package '$SINGLE_PACKAGE' not found in package list"
    echo "Available packages: ${PACKAGES[*]}"
    exit 1
  fi
  msg "Starting single package build: $SINGLE_PACKAGE"
  PACKAGES=("$SINGLE_PACKAGE")
else
  msg "Starting parallel build of ${#PACKAGES[@]} packages"
  msg "Max parallel jobs: $MAX_PARALLEL"
fi

msg "Base build directory: $BUILD_BASE_DIR"

# Install host dependencies once before starting parallel builds
msg "Installing host dependencies for all builds..."
ensure_host_deps() {
  msg "Installing host dependencies..."
  apt-get update &>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    debootstrap qemu-user-static binfmt-support qemu-system-misc \
    build-essential devscripts debhelper dpkg-dev fakeroot quilt \
    ubuntu-keyring debian-archive-keyring rsync e2fsprogs dosfstools \
    parted ca-certificates curl &>/dev/null
}
ensure_host_deps
export SKIP_HOST_DEPS=1  # Signal to build_single_package.sh to skip host deps

# Create job control arrays
declare -a BUILD_PIDS=()
declare -a BUILD_DIRS=()
declare -a BUILD_PACKAGES=()
declare -a BUILD_STATUS=()

# Function to start a build job
start_build() {
  local pkg="$1"
  local job_id="$2"
  local build_dir="$BUILD_BASE_DIR/rvbuild-$pkg"
  
  msg "Starting build job $job_id: $pkg -> $build_dir"
  
  # Start build in background
  "$(dirname "$0")/build_single_package.sh" "$pkg" "$build_dir" &
  local pid=$!
  
  # Store job info
  BUILD_PIDS+=($pid)
  BUILD_DIRS+=("$build_dir")
  BUILD_PACKAGES+=("$pkg")
  BUILD_STATUS+=("RUNNING")
  
  msg "Job $job_id started: PID=$pid, Package=$pkg"
}

# Function to wait for any job to complete
wait_for_completion() {
  # First, collect all actually running PIDs
  local running_pids=()
  local i
  
  for i in "${!BUILD_PIDS[@]}"; do
    local pid="${BUILD_PIDS[$i]}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      running_pids+=("$pid")
    fi
  done
  
  if [[ ${#running_pids[@]} -eq 0 ]]; then
    return 1  # No running processes
  fi
  
  # Wait for any of the running processes to complete
  local completed_pid
  wait -n -p completed_pid
  local exit_code=$?

  # Update status for the completed process
  for i in "${!BUILD_PIDS[@]}"; do
    if [[ "${BUILD_PIDS[$i]}" == "$completed_pid" ]]; then
      local pkg="${BUILD_PACKAGES[$i]}"
      if [[ $exit_code -eq 0 ]]; then
        BUILD_STATUS[$i]="SUCCESS"
        msg "Job completed successfully: $pkg (PID=$completed_pid)"
      elif [[ $exit_code -eq 2 ]]; then
        BUILD_STATUS[$i]="SKIPPED"
        msg "Job skipped (already built): $pkg (PID=$completed_pid)"
      else
        BUILD_STATUS[$i]="FAILED"
        err "Job failed: $pkg (PID=$completed_pid, exit_code=$exit_code)"
      fi
      return $i # Return the index of the completed job
    fi
  done
}

# Function to count running jobs
count_running() {
  local count=0
  local i
  
  for i in "${!BUILD_PIDS[@]}"; do
    local pid="${BUILD_PIDS[$i]}"
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      # Process is actually running
      ((count++))
    elif [[ "${BUILD_STATUS[$i]}" == "RUNNING" ]]; then
      # Dead process detected - update status
      BUILD_STATUS[$i]="FAILED"
      warn "Process ${BUILD_PACKAGES[$i]} (PID=$pid) terminated unexpectedly"
    fi
  done
  
  echo $count
}

# Main execution
job_id=1

# Process all packages
for pkg in "${PACKAGES[@]}"; do
  # Wait if we've reached max parallel jobs
  while [[ $(count_running) -ge $MAX_PARALLEL ]]; do
    msg "Max parallel jobs ($MAX_PARALLEL) reached, waiting..."
    wait_for_completion
  done
  
  # Start new job
  start_build "$pkg" $job_id
  ((job_id++))
done

# Wait for all remaining jobs to complete
msg "All jobs started, waiting for completion..."
while [[ $(count_running) -gt 0 ]]; do
  wait_for_completion
done

# Report results
msg "All builds completed. Summary:"
echo "=================================================="
printf "%-20s %-10s %-30s\n" "PACKAGE" "STATUS" "BUILD_DIR"
echo "=================================================="

success_count=0
skipped_count=0
failed_count=0

for i in "${!BUILD_PACKAGES[@]}"; do
  local pkg="${BUILD_PACKAGES[$i]}"
  local status="${BUILD_STATUS[$i]}"
  local build_dir="${BUILD_DIRS[$i]}"
  
  printf "%-20s %-10s %-30s\n" "$pkg" "$status" "$build_dir"
  
  if [[ "$status" == "SUCCESS" ]]; then
    ((success_count++))
  elif [[ "$status" == "SKIPPED" ]]; then
    ((skipped_count++))
  else
    ((failed_count++))
  fi
done

echo "=================================================="
msg "Build Summary: $success_count successful, $skipped_count skipped, $failed_count failed"

if [[ $failed_count -gt 0 ]]; then
  err "Some builds failed. Check individual build directories for logs."
  exit 1
else
  if [[ $skipped_count -gt 0 ]]; then
    msg "All builds completed! ($skipped_count were already built and skipped)"
  else
    msg "All builds completed successfully!"
  fi
fi