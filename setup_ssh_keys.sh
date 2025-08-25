#!/usr/bin/env bash
# setup_ssh_keys.sh
# Setup SSH keys for multiple VM access
# Usage: sudo ./setup_ssh_keys.sh

set -euo pipefail

# ------------ Config ------------
SSH_KEY_DIR="/srv/ssh-keys"
KEY_NAME="builder_key"
BASE_DIR="/srv/qemu-base"
BASE_IMG_NAME="ubuntu-riscv-base.qcow2"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

create_ssh_keys() {
  msg "Setting up SSH keys for VM access..."
  
  # Create SSH keys directory
  mkdir -p "$SSH_KEY_DIR"
  chmod 700 "$SSH_KEY_DIR"
  
  # Generate SSH key pair if not exists
  if [[ ! -f "$SSH_KEY_DIR/${KEY_NAME}" ]]; then
    msg "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_DIR/${KEY_NAME}" -N "" -C "builder@riscv-ubuntu-vms"
    chmod 600 "$SSH_KEY_DIR/${KEY_NAME}"
    chmod 644 "$SSH_KEY_DIR/${KEY_NAME}.pub"
    msg "SSH key pair created:"
    msg "  Private key: $SSH_KEY_DIR/${KEY_NAME}"
    msg "  Public key: $SSH_KEY_DIR/${KEY_NAME}.pub"
  else
    msg "SSH key pair already exists"
  fi
  
  # Show public key
  msg "Public key content:"
  cat "$SSH_KEY_DIR/${KEY_NAME}.pub"
}

install_key_to_base_image() {
  msg "Installing SSH key to base image..."
  
  if [[ ! -f "$BASE_DIR/$BASE_IMG_NAME" ]]; then
    err "Base image not found: $BASE_DIR/$BASE_IMG_NAME"
    return 1
  fi
  
  # Convert qcow2 to raw for mounting
  local raw_image="/tmp/ssh-key-install-$$.img"
  qemu-img convert -f qcow2 -O raw "$BASE_DIR/$BASE_IMG_NAME" "$raw_image"
  
  # Setup loop device
  local loop_device
  loop_device=$(losetup --find --show "$raw_image")
  partprobe "$loop_device"
  sleep 1
  
  # Mount the partition
  local mount_point="/tmp/ssh-key-mount-$$"
  mkdir -p "$mount_point"
  mount "${loop_device}p1" "$mount_point"
  
  # Install SSH key for builder user
  msg "Installing SSH key for builder user..."
  mkdir -p "$mount_point/home/builder/.ssh"
  cp "$SSH_KEY_DIR/${KEY_NAME}.pub" "$mount_point/home/builder/.ssh/authorized_keys"
  chmod 700 "$mount_point/home/builder/.ssh"
  chmod 600 "$mount_point/home/builder/.ssh/authorized_keys"
  chown -R 1000:1000 "$mount_point/home/builder/.ssh"  # builder user UID:GID
  
  # Install SSH key for root user (optional)
  msg "Installing SSH key for root user..."
  mkdir -p "$mount_point/root/.ssh"
  cp "$SSH_KEY_DIR/${KEY_NAME}.pub" "$mount_point/root/.ssh/authorized_keys"
  chmod 700 "$mount_point/root/.ssh"
  chmod 600 "$mount_point/root/.ssh/authorized_keys"
  chown -R 0:0 "$mount_point/root/.ssh"  # root user UID:GID
  
  # Sync and cleanup
  sync
  umount "$mount_point"
  rmdir "$mount_point"
  losetup -d "$loop_device"
  
  # Convert back to qcow2
  msg "Converting image back to qcow2..."
  qemu-img convert -f raw -O qcow2 "$raw_image" "$BASE_DIR/$BASE_IMG_NAME.new"
  mv "$BASE_DIR/$BASE_IMG_NAME.new" "$BASE_DIR/$BASE_IMG_NAME"
  rm "$raw_image"
  
  msg "SSH key installed to base image successfully"
}

create_ssh_config() {
  msg "Creating SSH configuration for VM access..."
  
  # Create SSH config template
  cat > "$SSH_KEY_DIR/ssh_config" << EOF
# SSH configuration for RISC-V Ubuntu VMs
Host riscv-vm-*
    HostName localhost
    User builder
    IdentityFile $SSH_KEY_DIR/$KEY_NAME
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 3

# Example usage:
# ssh -F $SSH_KEY_DIR/ssh_config -p 2222 riscv-vm-binutils
# ssh -F $SSH_KEY_DIR/ssh_config -p 2223 riscv-vm-tar
EOF

  chmod 644 "$SSH_KEY_DIR/ssh_config"
  msg "SSH config created: $SSH_KEY_DIR/ssh_config"
}

create_vm_connection_script() {
  msg "Creating VM connection helper script..."
  
  cat > "$SSH_KEY_DIR/connect_vm.sh" << 'EOF'
#!/bin/bash
# connect_vm.sh - Connect to RISC-V VM via SSH
# Usage: ./connect_vm.sh <vm_name> <port> [command]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/builder_key"
SSH_CONFIG="$SCRIPT_DIR/ssh_config"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <vm_name> <port> [command]"
    echo "Examples:"
    echo "  $0 binutils 2222"
    echo "  $0 binutils 2222 'apt update'"
    echo "  $0 binutils 2222 'build-package binutils'"
    exit 1
fi

VM_NAME="$1"
VM_PORT="$2"
COMMAND="${3:-}"

# SSH connection options for no caching and auto-accept
SSH_OPTS=(
    -F "$SSH_CONFIG"
    -p "$VM_PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -i "$SSH_KEY"
)

if [[ -n "$COMMAND" ]]; then
    # Execute command and exit
    echo "Executing on riscv-vm-$VM_NAME (port $VM_PORT): $COMMAND"
    ssh "${SSH_OPTS[@]}" builder@localhost "$COMMAND"
else
    # Interactive session
    echo "Connecting to riscv-vm-$VM_NAME (port $VM_PORT)..."
    ssh "${SSH_OPTS[@]}" builder@localhost
fi
EOF

  chmod +x "$SSH_KEY_DIR/connect_vm.sh"
  msg "VM connection script created: $SSH_KEY_DIR/connect_vm.sh"
}

create_build_script() {
  msg "Creating package build helper script..."
  
  cat > "$SSH_KEY_DIR/build_package.sh" << 'EOF'
#!/bin/bash
# build_package.sh - Build package in RISC-V VM via SSH
# Usage: ./build_package.sh <vm_name> <port> <package_name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECT_SCRIPT="$SCRIPT_DIR/connect_vm.sh"

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <vm_name> <port> <package_name>"
    echo "Example: $0 binutils 2222 binutils"
    exit 1
fi

VM_NAME="$1"
VM_PORT="$2"
PACKAGE_NAME="$3"

echo "Building package '$PACKAGE_NAME' in riscv-vm-$VM_NAME (port $VM_PORT)..."

# Build commands
BUILD_COMMANDS="
    set -e
    echo 'Starting package build for $PACKAGE_NAME...'
    cd /home/builder/build
    rm -rf ${PACKAGE_NAME}*
    
    echo 'Downloading source package...'
    apt-get source $PACKAGE_NAME
    
    echo 'Installing build dependencies...'
    sudo apt-get build-dep -y $PACKAGE_NAME
    
    echo 'Finding source directory...'
    SRC_DIR=\$(find . -maxdepth 1 -type d -name '${PACKAGE_NAME}-*' | head -n1)
    if [[ -z \"\$SRC_DIR\" ]]; then
        echo 'Error: Source directory not found'
        exit 1
    fi
    
    echo \"Building in directory: \$SRC_DIR\"
    cd \"\$SRC_DIR\"
    
    echo 'Building package...'
    dpkg-buildpackage -us -uc -b -j1
    
    echo 'Copying results...'
    cd ..
    cp *.deb /home/builder/output/ 2>/dev/null || echo 'No .deb files generated'
    
    echo 'Build completed successfully!'
    ls -la /home/builder/output/
"

"$CONNECT_SCRIPT" "$VM_NAME" "$VM_PORT" "$BUILD_COMMANDS"
EOF

  chmod +x "$SSH_KEY_DIR/build_package.sh"
  msg "Package build script created: $SSH_KEY_DIR/build_package.sh"
}

test_ssh_connection() {
  msg "Testing SSH connection to current VM..."
  
  # Test if VM is running on default port
  local test_port="2222"
  if netstat -tuln | grep -q ":$test_port "; then
    msg "Testing connection to port $test_port..."
    
    # Test connection
    if ssh -i "$SSH_KEY_DIR/$KEY_NAME" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=5 \
           -p "$test_port" \
           builder@localhost 'echo "SSH key authentication successful!"' 2>/dev/null; then
      msg "✅ SSH key authentication test PASSED"
    else
      warn "❌ SSH key authentication test FAILED"
      msg "Try: ssh -i $SSH_KEY_DIR/$KEY_NAME -p $test_port builder@localhost"
    fi
  else
    msg "No VM running on port $test_port for testing"
  fi
}

# ------------ Main Process ------------
need_sudo

msg "Setting up SSH key-based authentication for multiple VMs..."
msg "SSH Key Directory: $SSH_KEY_DIR"

# Create SSH keys and configuration
create_ssh_keys
install_key_to_base_image
create_ssh_config
create_vm_connection_script
create_build_script
test_ssh_connection

msg "============================================"
msg "SSH Key Setup Completed Successfully!"
msg "============================================"
msg ""
msg "SSH Key Files:"
msg "  Private Key: $SSH_KEY_DIR/$KEY_NAME"
msg "  Public Key: $SSH_KEY_DIR/$KEY_NAME.pub" 
msg "  SSH Config: $SSH_KEY_DIR/ssh_config"
msg ""
msg "Helper Scripts:"
msg "  Connect to VM: $SSH_KEY_DIR/connect_vm.sh"
msg "  Build Package: $SSH_KEY_DIR/build_package.sh"
msg ""
msg "Usage Examples:"
msg "  # Connect to VM interactively"
msg "  $SSH_KEY_DIR/connect_vm.sh binutils 2222"
msg ""
msg "  # Execute command in VM"
msg "  $SSH_KEY_DIR/connect_vm.sh binutils 2222 'uname -a'"
msg ""
msg "  # Build package in VM"
msg "  $SSH_KEY_DIR/build_package.sh binutils 2222 binutils"
msg ""
msg "  # Direct SSH (no caching)"
msg "  ssh -i $SSH_KEY_DIR/$KEY_NAME -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 builder@localhost"
msg "============================================"