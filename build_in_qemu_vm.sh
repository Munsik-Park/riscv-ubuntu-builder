#!/usr/bin/env bash
# build_in_qemu_vm.sh
# Build package inside QEMU VM using SSH
# Usage: ./build_in_qemu_vm.sh <package_name>

set -euo pipefail

PACKAGE_NAME="${1:-}"
if [[ -z "$PACKAGE_NAME" ]]; then
    echo "Usage: $0 <package_name>"
    echo "Example: $0 tar"
    exit 1
fi

# ------------ Config ------------
VM_BASE_DIR="${VM_BASE_DIR:-/srv/qemu-vms}"
VM_DIR="$VM_BASE_DIR/$PACKAGE_NAME"
BUILD_OUTPUT_DIR="$VM_DIR/build-output"
SSH_PORT_BASE=2222
SSH_PORT=$((SSH_PORT_BASE + $(echo "$PACKAGE_NAME" | cksum | cut -d' ' -f1) % 1000))

# SSH Configuration
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
VM_USER="builder"
VM_HOST="localhost"

# Build Configuration
BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"  # 1 hour timeout
VM_STARTUP_TIMEOUT="${VM_STARTUP_TIMEOUT:-180}"  # 3 minutes to boot

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

cleanup_on_exit() {
  local exit_code=$?
  
  # Kill VM if running
  if [[ -n "${VM_PID:-}" ]] && kill -0 "$VM_PID" 2>/dev/null; then
    msg "Shutting down VM (PID: $VM_PID)..."
    kill -TERM "$VM_PID" 2>/dev/null || true
    sleep 5
    if kill -0 "$VM_PID" 2>/dev/null; then
      kill -KILL "$VM_PID" 2>/dev/null || true
    fi
  fi
  
  if [[ $exit_code -ne 0 ]]; then
    err "Build failed for package: $PACKAGE_NAME"
  else
    msg "Build completed for package: $PACKAGE_NAME"
  fi
}

trap cleanup_on_exit EXIT

check_vm_image() {
  if [[ ! -d "$VM_DIR" ]]; then
    err "VM directory not found: $VM_DIR"
    err "Please run: sudo ./build_qemu_vm_image.sh $PACKAGE_NAME"
    exit 1
  fi
  
  if [[ ! -f "$VM_DIR/start-vm.sh" ]]; then
    err "VM startup script not found: $VM_DIR/start-vm.sh"
    err "Please rebuild VM image: sudo ./build_qemu_vm_image.sh $PACKAGE_NAME"
    exit 1
  fi
  
  msg "VM image found for package: $PACKAGE_NAME"
}

start_vm() {
  msg "Starting VM for $PACKAGE_NAME (SSH port: $SSH_PORT)..."
  
  # Start VM in background
  cd "$VM_DIR"
  ./start-vm.sh > "$VM_DIR/vm-console.log" 2>&1 &
  VM_PID=$!
  
  msg "VM started with PID: $VM_PID"
  msg "Console log: $VM_DIR/vm-console.log"
}

wait_for_ssh() {
  msg "Waiting for SSH to become available..."
  local count=0
  
  while [[ $count -lt $VM_STARTUP_TIMEOUT ]]; do
    if ssh $SSH_OPTS -p "$SSH_PORT" "$VM_USER@$VM_HOST" "echo 'SSH ready'" >/dev/null 2>&1; then
      msg "SSH connection established after ${count} seconds"
      return 0
    fi
    
    # Check if VM process is still running
    if ! kill -0 "$VM_PID" 2>/dev/null; then
      err "VM process died during startup"
      if [[ -f "$VM_DIR/vm-console.log" ]]; then
        err "Console log:"
        tail -20 "$VM_DIR/vm-console.log" >&2
      fi
      exit 1
    fi
    
    sleep 1
    ((count++))
    
    # Progress indicator
    if ((count % 30 == 0)); then
      msg "Still waiting for SSH... (${count}/${VM_STARTUP_TIMEOUT})"
    fi
  done
  
  err "SSH connection timeout after $VM_STARTUP_TIMEOUT seconds"
  return 1
}

prepare_build_environment() {
  msg "Preparing build environment in VM..."
  
  # Create build script inside VM
  ssh $SSH_OPTS -p "$SSH_PORT" "$VM_USER@$VM_HOST" 'cat > build-package.sh' <<'EOSSH'
#!/bin/bash
set -euo pipefail

PACKAGE_NAME="$1"
BUILD_DIR="/home/builder/build"
OUTPUT_DIR="/home/builder/output"

msg() { echo -e "\033[1;32m[VM $(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[VM $(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[VM $(date +'%H:%M:%S')] $*\033[0m" >&2; }

msg "Starting build for package: $PACKAGE_NAME"

# Create directories
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
cd "$BUILD_DIR"

# Download source
msg "Downloading source for $PACKAGE_NAME..."
apt-get source "$PACKAGE_NAME"

# Find source directory
SOURCE_DIR=$(find . -maxdepth 1 -type d -name "${PACKAGE_NAME}-*" | head -n1)
if [[ -z "$SOURCE_DIR" ]]; then
    err "Source directory not found for $PACKAGE_NAME"
    exit 1
fi

msg "Found source directory: $SOURCE_DIR"
cd "$SOURCE_DIR"

# Build package
msg "Building $PACKAGE_NAME..."
export DEB_BUILD_OPTIONS="parallel=1 reproducible=+all"
dpkg-buildpackage -us -uc -b -j1

# Copy results
cd ..
msg "Copying build results..."
cp -v *.deb "$OUTPUT_DIR/" 2>/dev/null || {
    err "No .deb files found after build"
    exit 1
}

# List results
msg "Build completed successfully!"
msg "Generated packages:"
ls -la "$OUTPUT_DIR"/*.deb

EOSSH
  
  # Make script executable
  ssh $SSH_OPTS -p "$SSH_PORT" "$VM_USER@$VM_HOST" "chmod +x build-package.sh"
  
  msg "Build environment prepared"
}

execute_build() {
  msg "Executing build in VM..."
  
  # Execute build with timeout
  if timeout "$BUILD_TIMEOUT" ssh $SSH_OPTS -p "$SSH_PORT" "$VM_USER@$VM_HOST" \
    "./build-package.sh '$PACKAGE_NAME'" 2>&1 | tee "$VM_DIR/build.log"; then
    msg "Build completed successfully"
  else
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      err "Build timed out after $BUILD_TIMEOUT seconds"
    else
      err "Build failed with exit code: $exit_code"
    fi
    return 1
  fi
}

collect_results() {
  msg "Collecting build results..."
  
  mkdir -p "$BUILD_OUTPUT_DIR"
  
  # Download built packages
  if scp $SSH_OPTS -P "$SSH_PORT" "$VM_USER@$VM_HOST:/home/builder/output/*.deb" "$BUILD_OUTPUT_DIR/" 2>/dev/null; then
    msg "Build results copied to: $BUILD_OUTPUT_DIR"
    msg "Generated packages:"
    ls -la "$BUILD_OUTPUT_DIR"/*.deb
    return 0
  else
    err "Failed to collect build results"
    return 1
  fi
}

shutdown_vm() {
  if [[ -n "${VM_PID:-}" ]] && kill -0 "$VM_PID" 2>/dev/null; then
    msg "Gracefully shutting down VM..."
    
    # Try graceful shutdown via SSH first
    ssh $SSH_OPTS -p "$SSH_PORT" "$VM_USER@$VM_HOST" "sudo shutdown -h now" 2>/dev/null || true
    
    # Wait for graceful shutdown
    local count=0
    while [[ $count -lt 30 ]] && kill -0 "$VM_PID" 2>/dev/null; do
      sleep 1
      ((count++))
    done
    
    # Force kill if still running
    if kill -0 "$VM_PID" 2>/dev/null; then
      warn "Forcing VM shutdown..."
      kill -TERM "$VM_PID" 2>/dev/null || true
      sleep 2
      kill -KILL "$VM_PID" 2>/dev/null || true
    fi
    
    msg "VM shutdown completed"
  fi
}

show_build_summary() {
  msg "=================================="
  msg "Build Summary for $PACKAGE_NAME"
  msg "=================================="
  msg "VM directory: $VM_DIR"
  msg "Build log: $VM_DIR/build.log"
  msg "Console log: $VM_DIR/vm-console.log"
  msg "Output directory: $BUILD_OUTPUT_DIR"
  
  if [[ -d "$BUILD_OUTPUT_DIR" ]] && ls "$BUILD_OUTPUT_DIR"/*.deb >/dev/null 2>&1; then
    msg ""
    msg "Generated packages:"
    ls -la "$BUILD_OUTPUT_DIR"/*.deb
    msg ""
    msg "✅ Build successful!"
  else
    msg ""
    msg "❌ Build failed - no packages generated"
  fi
  msg "=================================="
}

# ------------ Main Process ------------

msg "Building package $PACKAGE_NAME using QEMU VM"
msg "VM SSH port: $SSH_PORT"

# Step 1: Check VM image exists
check_vm_image

# Step 2: Start VM
start_vm

# Step 3: Wait for SSH
wait_for_ssh

# Step 4: Prepare build environment
prepare_build_environment

# Step 5: Execute build
execute_build

# Step 6: Collect results
collect_results

# Step 7: Shutdown VM
shutdown_vm

# Step 8: Show summary
show_build_summary