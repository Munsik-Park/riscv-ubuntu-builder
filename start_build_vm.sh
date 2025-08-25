#!/usr/bin/env bash
# start_build_vm.sh
# Start a package-specific VM for building
# Usage: ./start_build_vm.sh <package_name>

set -euo pipefail

PACKAGE_NAME="${1:-}"
if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package_name>"
    echo "Example: $0 tar"
    exit 1
fi

# ------------ Config ------------
SNAPSHOTS_DIR="${SNAPSHOTS_DIR:-/srv/qemu-snapshots}"
VM_DIR="$SNAPSHOTS_DIR/$PACKAGE_NAME"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

check_snapshot() {
  if [[ ! -d "$VM_DIR" ]]; then
    err "Package snapshot not found: $VM_DIR"
    err "Please create snapshot first: sudo ./create_package_snapshot.sh $PACKAGE_NAME"
    exit 1
  fi
  
  if [[ ! -f "$VM_DIR/start-vm.sh" ]]; then
    err "VM startup script not found: $VM_DIR/start-vm.sh"
    err "Please recreate snapshot: sudo ./create_package_snapshot.sh $PACKAGE_NAME"
    exit 1
  fi
}

show_vm_info() {
  local config_file="$VM_DIR/vm-config.json"
  
  if [[ -f "$config_file" ]]; then
    msg "VM Configuration:"
    msg "  Package: $(jq -r '.package' "$config_file")"
    msg "  SSH Port: $(jq -r '.ssh_port' "$config_file")"
    msg "  Memory: $(jq -r '.memory' "$config_file")MB"
    msg "  CPUs: $(jq -r '.cpus' "$config_file")"
    msg "  Created: $(jq -r '.created' "$config_file")"
  fi
  
  msg ""
  msg "VM directory: $VM_DIR"
  msg ""
  msg "After VM starts, connect with:"
  msg "  ssh -p $(jq -r '.ssh_port' "$config_file" 2>/dev/null || echo 'SSH_PORT') builder@localhost"
  msg ""
  msg "In the VM, build the package with:"
  msg "  build-package $PACKAGE_NAME"
  msg ""
}

# ------------ Main Process ------------

msg "Starting build VM for package: $PACKAGE_NAME"

# Check if snapshot exists
check_snapshot

# Show VM information
show_vm_info

# Start the VM
msg "Starting VM..."
exec "$VM_DIR/start-vm.sh" "$@"