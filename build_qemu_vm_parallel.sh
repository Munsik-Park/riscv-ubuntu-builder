#!/usr/bin/env bash
# build_qemu_vm_parallel.sh
# Build multiple packages in parallel using separate QEMU VMs
# Usage: ./build_qemu_vm_parallel.sh [max_parallel]

set -euo pipefail

MAX_PARALLEL="${1:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_LIST_FILE="${PACKAGE_LIST_FILE:-$SCRIPT_DIR/build_packages.list}"
VM_BASE_DIR="${VM_BASE_DIR:-/srv/qemu-vms}"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

load_packages() {
    if [[ ! -f "$PACKAGE_LIST_FILE" ]]; then
        err "Package list file not found: $PACKAGE_LIST_FILE"
        exit 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" ]] && continue
        echo "$line"
    done < "$PACKAGE_LIST_FILE"
}

show_usage() {
    cat << EOF
Usage: $0 [max_parallel]

Build packages from build_packages.list using separate QEMU VMs.

Arguments:
  max_parallel    Maximum number of parallel VM builds (default: 2)

Commands:
  $0              # Build with 2 parallel VMs
  $0 3            # Build with 3 parallel VMs
  $0 status       # Show build status
  $0 clean        # Clean all VMs
  
Examples:
  $0              # Build all packages (2 parallel)
  $0 1            # Build sequentially
  $0 status       # Check status
  $0 clean        # Clean up all VMs

Environment variables:
  PACKAGE_LIST_FILE   Path to package list (default: ./build_packages.list)
  VM_BASE_DIR        Base directory for VMs (default: /srv/qemu-vms)
EOF
}

check_dependencies() {
    local missing_deps=()
    
    for cmd in qemu-system-riscv64 qemu-img ssh scp nc; do
        if ! command -v "$cmd" >/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        err "Missing required dependencies: ${missing_deps[*]}"
        err "Please install: sudo apt-get install qemu-system-misc qemu-utils openssh-client netcat-openbsd"
        exit 1
    fi
}

show_build_status() {
    msg "QEMU VM Build Status:"
    echo
    
    "$SCRIPT_DIR/qemu_vm_manager.sh" status
    
    echo
    msg "Build output directories:"
    if [[ -d "$VM_BASE_DIR" ]]; then
        for vm_dir in "$VM_BASE_DIR"/*; do
            if [[ -d "$vm_dir" ]]; then
                local package=$(basename "$vm_dir")
                local output_dir="$vm_dir/build-output"
                if [[ -d "$output_dir" ]] && ls "$output_dir"/*.deb >/dev/null 2>&1; then
                    local deb_count=$(ls "$output_dir"/*.deb | wc -l)
                    echo "  ✅ $package: $deb_count packages in $output_dir"
                elif [[ -d "$output_dir" ]]; then
                    echo "  🔄 $package: build in progress (output dir exists)"
                else
                    echo "  ⏳ $package: not started"
                fi
            fi
        done
    else
        echo "  No VMs found"
    fi
}

clean_all() {
    msg "Cleaning all QEMU VMs and build outputs..."
    "$SCRIPT_DIR/qemu_vm_manager.sh" clean-all
    msg "All VMs cleaned"
}

build_package_vm() {
    local package="$1"
    local log_file="$VM_BASE_DIR/build-$package.log"
    
    msg "Starting VM build for package: $package"
    
    {
        echo "=== VM Build Log for $package ==="
        echo "Started at: $(date)"
        echo "Package: $package"
        echo "=================================="
        echo
        
        # Step 1: Create VM image
        echo "Step 1/2: Creating VM image..."
        if sudo "$SCRIPT_DIR/build_qemu_vm_image.sh" "$package"; then
            echo "✅ VM image created successfully"
        else
            echo "❌ VM image creation failed"
            exit 1
        fi
        
        echo
        echo "Step 2/2: Building package in VM..."
        if "$SCRIPT_DIR/build_in_qemu_vm.sh" "$package"; then
            echo "✅ Package build completed successfully"
        else
            echo "❌ Package build failed"
            exit 1
        fi
        
        echo
        echo "=== Build completed at: $(date) ==="
        
    } > "$log_file" 2>&1
    
    if [[ $? -eq 0 ]]; then
        msg "✅ Package $package completed successfully"
        return 0
    else
        err "❌ Package $package failed"
        return 1
    fi
}

wait_for_slot() {
    while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; do
        sleep 1
    done
}

show_final_summary() {
    local packages=("$@")
    local total=${#packages[@]}
    local success=0
    local failed=0
    
    msg "=================================="
    msg "Final Build Summary"
    msg "=================================="
    
    for package in "${packages[@]}"; do
        local output_dir="$VM_BASE_DIR/$package/build-output"
        if [[ -d "$output_dir" ]] && ls "$output_dir"/*.deb >/dev/null 2>&1; then
            local deb_count=$(ls "$output_dir"/*.deb | wc -l)
            echo "  ✅ $package: $deb_count packages"
            ((success++))
        else
            echo "  ❌ $package: failed"
            ((failed++))
        fi
    done
    
    echo
    msg "Results: $success successful, $failed failed, $total total"
    
    if [[ $success -gt 0 ]]; then
        msg "All build outputs available in: $VM_BASE_DIR/*/build-output/"
        msg "VM management: $SCRIPT_DIR/qemu_vm_manager.sh"
    fi
    
    if [[ $failed -gt 0 ]]; then
        warn "Check build logs: $VM_BASE_DIR/build-*.log"
    fi
    
    msg "=================================="
}

# ------------ Main Logic ------------

case "${1:-build}" in
    status)
        show_build_status
        exit 0
        ;;
    clean)
        clean_all
        exit 0
        ;;
    -h|--help|help)
        show_usage
        exit 0
        ;;
    [0-9]*)
        # Numeric argument - continue with build
        ;;
    build)
        # Default build command
        MAX_PARALLEL=2
        ;;
    *)
        err "Invalid argument: ${1}"
        show_usage
        exit 1
        ;;
esac

# Validate parallel count
if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [[ "$MAX_PARALLEL" -lt 1 ]]; then
    err "Invalid parallel count: $MAX_PARALLEL"
    exit 1
fi

# Check dependencies
check_dependencies

# Load packages
packages=($(load_packages))
if [[ ${#packages[@]} -eq 0 ]]; then
    err "No packages found in $PACKAGE_LIST_FILE"
    exit 1
fi

msg "Starting QEMU VM parallel build"
msg "Packages to build: ${packages[*]}"
msg "Max parallel VMs: $MAX_PARALLEL"
msg "VM base directory: $VM_BASE_DIR"

# Create base directory
mkdir -p "$VM_BASE_DIR"

# Start builds
msg "Starting parallel builds..."
for package in "${packages[@]}"; do
    wait_for_slot
    
    msg "Launching build for: $package"
    build_package_vm "$package" &
    
    # Small delay to avoid overwhelming the system
    sleep 2
done

# Wait for all builds to complete
msg "Waiting for all builds to complete..."
wait

# Show final summary
show_final_summary "${packages[@]}"