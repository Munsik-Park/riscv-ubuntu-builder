#!/usr/bin/env bash
# build_qemu_parallel.sh
# Build multiple packages in separate QEMU environments in parallel
# Usage: sudo ./build_qemu_parallel.sh [max_parallel]

set -euo pipefail

MAX_PARALLEL="${1:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_LIST_FILE="${PACKAGE_LIST_FILE:-$SCRIPT_DIR/build_packages.list}"
BASE_WORKDIR="${BASE_WORKDIR:-/srv/qemu-builds}"

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
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" ]] && continue
        
        echo "$line"
    done < "$PACKAGE_LIST_FILE"
}

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

show_usage() {
    cat << EOF
Usage: $0 [max_parallel]

Build packages from build_packages.list in separate QEMU environments.

Arguments:
  max_parallel    Maximum number of parallel builds (default: 2)

Examples:
  $0              # Build with 2 parallel processes
  $0 3            # Build with 3 parallel processes
  $0 1            # Build sequentially

Environment variables:
  PACKAGE_LIST_FILE   Path to package list file (default: ./build_packages.list)
  BASE_WORKDIR       Base directory for QEMU builds (default: /srv/qemu-builds)
EOF
}

cleanup_all() {
    msg "Cleaning up all QEMU build environments..."
    
    # Use dedicated cleanup script
    if [[ -f "$SCRIPT_DIR/clean_qemu_builds.sh" ]]; then
        "$SCRIPT_DIR/clean_qemu_builds.sh" all
    else
        # Fallback manual cleanup
        warn "Dedicated cleanup script not found, using fallback method"
        
        # Kill any running build processes
        pkill -f "build_qemu_single.sh" 2>/dev/null || true
        sleep 2
        pkill -9 -f "build_qemu_single.sh" 2>/dev/null || true
        
        # Cleanup mounts and directories
        for workdir in "$BASE_WORKDIR"/*; do
            [[ -d "$workdir" ]] || continue
            for mp in "$workdir"/{target-rootfs,builder-base}/{proc,sys,dev/pts,dev}; do
                if mountpoint -q "$mp" 2>/dev/null; then
                    warn "Cleaning up mount: $mp"
                    umount -l "$mp" 2>/dev/null || true
                fi
            done
            rm -rf "$workdir" 2>/dev/null || true
        done
        
        # Remove base directory if empty
        rmdir "$BASE_WORKDIR" 2>/dev/null || true
    fi
    
    msg "Cleanup completed"
}

build_package() {
    local package="$1"
    local log_file="$BASE_WORKDIR/$package/build.log"
    
    msg "Starting build for package: $package"
    
    mkdir -p "$(dirname "$log_file")"
    
    if "$SCRIPT_DIR/build_qemu_single.sh" "$package" &> "$log_file"; then
        msg "✅ Package $package completed successfully"
        return 0
    else
        err "❌ Package $package failed"
        return 1
    fi
}

show_status() {
    local packages=($(load_packages))
    
    msg "QEMU Build Status:"
    echo
    
    for pkg in "${packages[@]}"; do
        local workdir="$BASE_WORKDIR/$pkg"
        local outdir="$workdir/out"
        local log_file="$workdir/build.log"
        
        if [[ -d "$outdir" ]] && [[ -n "$(find "$outdir" -name "*.deb" 2>/dev/null)" ]]; then
            local deb_count=$(find "$outdir" -name "*.deb" 2>/dev/null | wc -l)
            echo "  ✅ $pkg (completed - $deb_count .deb files)"
        elif [[ -f "$log_file" ]]; then
            if pgrep -f "build_qemu_single.sh $pkg" >/dev/null; then
                echo "  🔄 $pkg (building)"
            else
                echo "  ❌ $pkg (failed)"
            fi
        else
            echo "  ⏳ $pkg (pending)"
        fi
    done
    echo
    
    local running=$(pgrep -f "build_qemu_single.sh" | wc -l)
    msg "Active builds: $running"
}

# ------------ Main Logic ------------

case "${1:-}" in
    clean)
        cleanup_all
        exit 0
        ;;
    status)
        show_status
        exit 0
        ;;
    -h|--help|help)
        show_usage
        exit 0
        ;;
    *)
        if [[ -n "${1:-}" && ! "$1" =~ ^[0-9]+$ ]]; then
            err "Invalid argument: $1"
            show_usage
            exit 1
        fi
        ;;
esac

need_sudo

packages=($(load_packages))
if [[ ${#packages[@]} -eq 0 ]]; then
    err "No packages found in $PACKAGE_LIST_FILE"
    exit 1
fi

msg "Starting QEMU parallel build"
msg "Packages to build: ${packages[*]}"
msg "Max parallel builds: $MAX_PARALLEL"
msg "Base work directory: $BASE_WORKDIR"

mkdir -p "$BASE_WORKDIR"

# Build packages in parallel
active_jobs=0
for package in "${packages[@]}"; do
    # Wait if we've reached max parallel limit
    while [[ $active_jobs -ge $MAX_PARALLEL ]]; do
        wait -n  # Wait for any job to complete
        active_jobs=$((active_jobs - 1))
    done
    
    # Start build in background
    build_package "$package" &
    active_jobs=$((active_jobs + 1))
    
    sleep 1  # Small delay to avoid overwhelming the system
done

# Wait for all remaining jobs
wait

msg "All QEMU builds completed!"
show_status