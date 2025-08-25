#!/usr/bin/env bash
# build_all_vm_images.sh
# Create VM images for all packages in build_packages.list
# Usage: sudo ./build_all_vm_images.sh [parallel_count]

set -euo pipefail

# ------------ Config ------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_LIST_FILE="${PACKAGE_LIST_FILE:-$SCRIPT_DIR/build_packages.list}"
MAX_PARALLEL="${1:-3}"  # Default: 3 VMs in parallel

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
  
  # Kill any remaining background processes
  if [[ -n "${CHILD_PIDS:-}" ]]; then
    for pid in $CHILD_PIDS; do
      if kill -0 "$pid" 2>/dev/null; then
        warn "Terminating background process: $pid"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
  fi
  
  if [[ $exit_code -ne 0 ]]; then
    err "VM images creation failed"
  else
    msg "VM images creation completed"
  fi
}

trap cleanup_on_exit EXIT

check_base_image() {
  local base_image="/srv/qemu-base/ubuntu-riscv-base.qcow2"
  
  if [[ ! -f "$base_image" ]]; then
    err "Base image not found: $base_image"
    err "Please run: sudo ./build_base_image.sh"
    exit 1
  fi
  
  msg "Base image verified: $base_image"
}

read_package_list() {
  if [[ ! -f "$PACKAGE_LIST_FILE" ]]; then
    err "Package list file not found: $PACKAGE_LIST_FILE"
    exit 1
  fi
  
  # Read packages from file, filter comments and empty lines, trim whitespace
  mapfile -t PACKAGES < <(grep -v '^#' "$PACKAGE_LIST_FILE" | grep -v '^$' | sed 's/[[:space:]]*#.*$//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u)
  
  if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    err "No packages found in: $PACKAGE_LIST_FILE"
    exit 1
  fi
  
  msg "Found ${#PACKAGES[@]} packages to create VM images for:"
  printf "  - %s\n" "${PACKAGES[@]}"
}

create_vm_image() {
  local package_name="$1"
  local log_file="/tmp/build_vm_${package_name}_$$.log"
  
  msg "Creating VM image for: $package_name"
  
  # Run build_qemu_vm_image.sh for this package
  if "$SCRIPT_DIR/build_qemu_vm_image.sh" "$package_name" > "$log_file" 2>&1; then
    msg "✅ VM image created successfully for: $package_name"
    # Keep last few lines of success log
    tail -5 "$log_file" | sed "s/^/[$package_name] /"
  else
    err "❌ VM image creation failed for: $package_name"
    err "Log file: $log_file"
    echo "--- Error Log for $package_name ---"
    tail -20 "$log_file"
    echo "--- End Error Log ---"
    return 1
  fi
  
  # Cleanup successful log
  rm -f "$log_file"
}

create_vm_images_sequential() {
  msg "Creating VM images sequentially..."
  
  local success_count=0
  local failed_packages=()
  
  for package_name in "${PACKAGES[@]}"; do
    if create_vm_image "$package_name"; then
      ((success_count++))
    else
      failed_packages+=("$package_name")
    fi
  done
  
  msg "Sequential creation completed:"
  msg "  Successful: $success_count/${#PACKAGES[@]}"
  
  if [[ ${#failed_packages[@]} -gt 0 ]]; then
    warn "Failed packages:"
    printf "    - %s\n" "${failed_packages[@]}"
    return 1
  fi
}

create_vm_images_parallel() {
  msg "Creating VM images in parallel (max $MAX_PARALLEL concurrent)..."
  
  local active_jobs=0
  local completed=0
  local total=${#PACKAGES[@]}
  local failed_packages=()
  local success_packages=()
  
  # Track background processes
  declare -A job_packages
  declare -A job_logs
  CHILD_PIDS=""
  
  for package_name in "${PACKAGES[@]}"; do
    # Wait if we've reached max parallel jobs
    while [[ $active_jobs -ge $MAX_PARALLEL ]]; do
      check_completed_jobs
      sleep 1
    done
    
    # Start new job
    local log_file="/tmp/build_vm_${package_name}_$$.log"
    "$SCRIPT_DIR/build_qemu_vm_image.sh" "$package_name" > "$log_file" 2>&1 &
    local job_pid=$!
    
    job_packages[$job_pid]="$package_name"
    job_logs[$job_pid]="$log_file"
    CHILD_PIDS="$CHILD_PIDS $job_pid"
    
    ((active_jobs++))
    msg "Started VM creation for $package_name (PID: $job_pid, Active: $active_jobs/$MAX_PARALLEL)"
  done
  
  # Wait for all remaining jobs
  while [[ $active_jobs -gt 0 ]]; do
    check_completed_jobs
    sleep 1
  done
  
  msg "Parallel creation completed:"
  msg "  Successful: ${#success_packages[@]}/$total"
  msg "  Failed: ${#failed_packages[@]}/$total"
  
  if [[ ${#success_packages[@]} -gt 0 ]]; then
    msg "Successful packages:"
    printf "    ✅ %s\n" "${success_packages[@]}"
  fi
  
  if [[ ${#failed_packages[@]} -gt 0 ]]; then
    warn "Failed packages:"
    printf "    ❌ %s\n" "${failed_packages[@]}"
    return 1
  fi
}

check_completed_jobs() {
  local pids_to_remove=()
  
  for pid in $CHILD_PIDS; do
    if ! kill -0 "$pid" 2>/dev/null; then
      # Job completed
      local package_name="${job_packages[$pid]}"
      local log_file="${job_logs[$pid]}"
      
      # Check exit status
      if wait "$pid" 2>/dev/null; then
        msg "✅ VM image completed for: $package_name"
        success_packages+=("$package_name")
        # Show last few lines of success log
        tail -3 "$log_file" | sed "s/^/[$package_name] /"
        rm -f "$log_file"
      else
        err "❌ VM image failed for: $package_name (log: $log_file)"
        failed_packages+=("$package_name")
        # Keep failed log for debugging
      fi
      
      # Remove from active tracking
      unset job_packages[$pid]
      unset job_logs[$pid]
      pids_to_remove+=("$pid")
      ((active_jobs--))
      ((completed++))
      
      msg "Progress: $completed/${#PACKAGES[@]} completed"
    fi
  done
  
  # Remove completed PIDs from tracking
  for remove_pid in "${pids_to_remove[@]}"; do
    CHILD_PIDS="${CHILD_PIDS// $remove_pid/}"
  done
}

verify_vm_images() {
  msg "Verifying created VM images..."
  
  local verified_count=0
  local missing_images=()
  
  for package_name in "${PACKAGES[@]}"; do
    local vm_dir="/srv/qemu-vms/$package_name"
    local vm_image="$vm_dir/ubuntu-${package_name}.qcow2"
    local start_script="$vm_dir/start-vm.sh"
    
    if [[ -f "$vm_image" && -f "$start_script" ]]; then
      local image_size=$(du -sh "$vm_image" 2>/dev/null | cut -f1)
      msg "✅ $package_name: $vm_image ($image_size)"
      ((verified_count++))
    else
      warn "❌ $package_name: Missing files"
      missing_images+=("$package_name")
    fi
  done
  
  msg "Verification completed: $verified_count/${#PACKAGES[@]} VM images verified"
  
  if [[ ${#missing_images[@]} -gt 0 ]]; then
    warn "Missing VM images:"
    printf "    - %s\n" "${missing_images[@]}"
    return 1
  fi
}

show_usage() {
  cat << EOF
Usage: $0 [parallel_count]

Create VM images for all packages listed in build_packages.list

Arguments:
  parallel_count    Maximum number of parallel VM creations (default: 3)
                   Use 1 for sequential creation

Examples:
  sudo $0           # Create with 3 parallel jobs
  sudo $0 1         # Create sequentially 
  sudo $0 5         # Create with 5 parallel jobs

Package list file: $PACKAGE_LIST_FILE

This script will:
1. Verify base image exists
2. Read package list from build_packages.list
3. Create VM image for each package
4. Verify all images were created successfully

VM images will be created in: /srv/qemu-vms/
EOF
}

show_summary() {
  msg "============================================="
  msg "VM Images Creation Summary"
  msg "============================================="
  msg "Package list file: $PACKAGE_LIST_FILE"
  msg "Total packages: ${#PACKAGES[@]}"
  msg "Parallel jobs: $MAX_PARALLEL"
  msg ""
  msg "VM images location: /srv/qemu-vms/"
  msg "Next steps:"
  msg "  # Start individual package builds"
  msg "  ./build_in_qemu_vm.sh <package_name>"
  msg ""
  msg "  # Or run parallel builds"
  msg "  sudo ./build_qemu_parallel.sh $MAX_PARALLEL"
  msg "============================================="
}

# ------------ Main Process ------------

# Handle help
case "${1:-}" in
  -h|--help|help)
    show_usage
    exit 0
    ;;
esac

need_sudo

msg "==============================================="
msg "Creating VM Images for All Packages"
msg "==============================================="
msg "Package list: $PACKAGE_LIST_FILE"
msg "Max parallel: $MAX_PARALLEL"
msg ""

# Main workflow
check_base_image
read_package_list

if [[ $MAX_PARALLEL -eq 1 ]]; then
  create_vm_images_sequential
else
  create_vm_images_parallel
fi

verify_vm_images
show_summary

msg "VM images creation completed successfully!"