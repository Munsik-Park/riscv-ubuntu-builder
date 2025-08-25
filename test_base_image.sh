#!/usr/bin/env bash
# test_base_image.sh
# Boot and test the base QEMU RISC-V image
# Usage: sudo ./test_base_image.sh [interactive|auto]

set -euo pipefail

# ------------ Config ------------
BASE_DIR="${BASE_DIR:-/srv/qemu-base}"
BASE_IMG_NAME="ubuntu-riscv-base.qcow2"
KERNEL_FILE="$BASE_DIR/fw_jump.elf"
UBOOT_FILE="$BASE_DIR/uboot.elf"

# VM Configuration for testing
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"

# Test mode
TEST_MODE="${1:-interactive}"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."; exit 1
  fi
}

check_base_image() {
  if [[ ! -f "$BASE_DIR/$BASE_IMG_NAME" ]]; then
    err "Base image not found: $BASE_DIR/$BASE_IMG_NAME"
    err "Please run: sudo ./build_base_image.sh first"
    exit 1
  fi
  
  if [[ ! -f "$KERNEL_FILE" ]]; then
    err "Kernel file not found: $KERNEL_FILE"
    exit 1
  fi
  
  msg "Base image found: $BASE_DIR/$BASE_IMG_NAME"
  msg "Image size: $(du -sh "$BASE_DIR/$BASE_IMG_NAME" | cut -f1)"
}

check_port_available() {
  local port="$1"
  if netstat -tuln | grep -q ":$port "; then
    err "Port $port is already in use"
    err "Please stop other QEMU instances or change SSH_PORT"
    exit 1
  fi
}

boot_vm_interactive() {
  msg "Starting QEMU RISC-V VM in interactive mode..."
  msg "VM Configuration:"
  msg "  Memory: ${VM_MEMORY}MB"
  msg "  CPUs: $VM_CPUS"
  msg "  SSH Port: $SSH_PORT"
  msg "  Image: $BASE_DIR/$BASE_IMG_NAME"
  msg ""
  msg "Boot process will be shown in console output"
  msg "After boot, you can:"
  msg "  - Login as root/root or builder/builder"
  msg "  - Test network: ping 8.8.8.8"
  msg "  - Test DNS: nslookup google.com"
  msg "  - Test package manager: apt update"
  msg ""
  msg "To exit QEMU: Press Ctrl+A then X"
  msg "To SSH from another terminal: ssh -p $SSH_PORT builder@localhost"
  msg ""
  
  read -p "Press Enter to start VM..." -r
  
  # Start QEMU with console output
  qemu-system-riscv64 \
    -machine virt \
    -cpu rv64 \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY" \
    -bios "$KERNEL_FILE" \
    -kernel "$UBOOT_FILE" \
    -drive file="$BASE_DIR/$BASE_IMG_NAME",format=qcow2,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-device,netdev=net0 \
    -nographic \
    -monitor telnet:127.0.0.1:55555,server,nowait
}

boot_vm_auto_test() {
  msg "Starting QEMU RISC-V VM for automated testing..."
  
  # Create temporary expect script for automated testing
  local expect_script="/tmp/qemu_test_$$.expect"
  
  cat > "$expect_script" << 'EOF'
#!/usr/bin/expect -f

set timeout 300
set vm_ready 0

# Start QEMU in background
spawn qemu-system-riscv64 -machine virt -cpu rv64 -smp 2 -m 4096 \
  -bios /srv/qemu-base/fw_jump.elf \
  -kernel /srv/qemu-base/uboot.elf \
  -drive file=/srv/qemu-base/ubuntu-riscv-base.qcow2,format=qcow2,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0,hostfwd=tcp::2223-:22 \
  -device virtio-net-device,netdev=net0 \
  -nographic

# Wait for boot process
expect {
    "login:" {
        send_user "\n=== BOOT SUCCESS: Login prompt appeared ===\n"
        set vm_ready 1
    }
    "Ubuntu" {
        send_user "\n=== Ubuntu system detected ===\n"
        exp_continue
    }
    timeout {
        send_user "\n=== TIMEOUT: VM did not boot within 5 minutes ===\n"
        exit 1
    }
    eof {
        send_user "\n=== ERROR: QEMU process ended unexpectedly ===\n"
        exit 1
    }
}

if {$vm_ready == 1} {
    # Login as root
    send "root\r"
    expect "Password:"
    send "root\r"
    
    expect "root@ubuntu-riscv-base:~#"
    send_user "\n=== LOGIN SUCCESS: Root login successful ===\n"
    
    # Test basic commands
    send "echo 'Testing basic system...'\r"
    expect "Testing basic system..."
    
    # Test network interface
    send "ip addr show\r"
    expect "root@ubuntu-riscv-base:~#"
    send_user "\n=== NETWORK: Interface check completed ===\n"
    
    # Test DNS resolution
    send "nslookup google.com\r"
    expect {
        "Address:" {
            send_user "\n=== DNS SUCCESS: DNS resolution working ===\n"
        }
        timeout {
            send_user "\n=== DNS WARNING: DNS resolution timed out ===\n"
        }
    }
    expect "root@ubuntu-riscv-base:~#"
    
    # Test package manager
    send "apt update 2>&1 | head -5\r"
    expect "root@ubuntu-riscv-base:~#"
    send_user "\n=== APT: Package manager test completed ===\n"
    
    # Test builder user
    send "su - builder\r"
    expect "builder@ubuntu-riscv-base:~$"
    send_user "\n=== USER SUCCESS: Builder user login successful ===\n"
    
    send "whoami\r"
    expect "builder"
    expect "builder@ubuntu-riscv-base:~$"
    
    send "exit\r"
    expect "root@ubuntu-riscv-base:~#"
    
    # Shutdown
    send "shutdown -h now\r"
    send_user "\n=== SHUTDOWN: Initiating clean shutdown ===\n"
    
    expect eof
    send_user "\n=== TEST COMPLETED SUCCESSFULLY ===\n"
    exit 0
} else {
    send_user "\n=== BOOT FAILED ===\n"
    exit 1
}
EOF

  chmod +x "$expect_script"
  
  if command -v expect >/dev/null 2>&1; then
    msg "Running automated boot test with expect..."
    "$expect_script"
    local exit_code=$?
    rm -f "$expect_script"
    return $exit_code
  else
    warn "expect not installed, falling back to basic boot test"
    rm -f "$expect_script"
    boot_vm_basic_test
  fi
}

boot_vm_basic_test() {
  msg "Starting basic boot test (10 minute timeout)..."
  
  # Start QEMU in background and capture output
  local log_file="/tmp/qemu_boot_test_$$.log"
  
  timeout 600 qemu-system-riscv64 \
    -machine virt \
    -cpu rv64 \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY" \
    -bios "$KERNEL_FILE" \
    -kernel "$UBOOT_FILE" \
    -drive file="$BASE_DIR/$BASE_IMG_NAME",format=qcow2,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net-device,netdev=net0 \
    -nographic > "$log_file" 2>&1 &
  
  local qemu_pid=$!
  msg "QEMU started with PID: $qemu_pid"
  msg "Boot log: $log_file"
  
  # Monitor boot progress
  local boot_timeout=300
  local elapsed=0
  
  while [[ $elapsed -lt $boot_timeout ]]; do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      err "QEMU process died unexpectedly"
      cat "$log_file"
      rm -f "$log_file"
      return 1
    fi
    
    # Check for login prompt in log
    if grep -q "login:" "$log_file" 2>/dev/null; then
      msg "SUCCESS: Login prompt detected after ${elapsed}s"
      kill "$qemu_pid" 2>/dev/null || true
      wait "$qemu_pid" 2>/dev/null || true
      
      # Show relevant boot messages
      msg "Boot summary:"
      grep -E "(Ubuntu|login|systemd|Failed|Error)" "$log_file" | tail -10 || true
      
      rm -f "$log_file"
      return 0
    fi
    
    sleep 5
    elapsed=$((elapsed + 5))
    
    if [[ $((elapsed % 30)) -eq 0 ]]; then
      msg "Boot in progress... ${elapsed}s elapsed"
    fi
  done
  
  err "TIMEOUT: No login prompt after ${boot_timeout}s"
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
  
  # Show last boot messages
  msg "Last boot messages:"
  tail -20 "$log_file" || true
  
  rm -f "$log_file"
  return 1
}

ssh_test_connection() {
  msg "Testing SSH connection to VM..."
  msg "Waiting for SSH service to be ready..."
  
  local ssh_timeout=60
  local elapsed=0
  
  while [[ $elapsed -lt $ssh_timeout ]]; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "$SSH_PORT" builder@localhost 'echo "SSH connection successful"' 2>/dev/null; then
      msg "SUCCESS: SSH connection established"
      return 0
    fi
    
    sleep 3
    elapsed=$((elapsed + 3))
    
    if [[ $((elapsed % 15)) -eq 0 ]]; then
      msg "Waiting for SSH... ${elapsed}s elapsed"
    fi
  done
  
  warn "SSH connection test failed or timed out"
  return 1
}

show_vm_info() {
  msg "=== VM Information ==="
  msg "Base Image: $BASE_DIR/$BASE_IMG_NAME"
  msg "Image Size: $(du -sh "$BASE_DIR/$BASE_IMG_NAME" 2>/dev/null | cut -f1 || echo 'Unknown')"
  msg "Memory: ${VM_MEMORY}MB"
  msg "CPUs: $VM_CPUS" 
  msg "SSH Port: $SSH_PORT"
  msg ""
  msg "After boot, connect with:"
  msg "  ssh -p $SSH_PORT builder@localhost"
  msg "  ssh -p $SSH_PORT root@localhost"
  msg ""
  msg "Default credentials:"
  msg "  root:root"
  msg "  builder:builder"
  msg "====================="
}

# ------------ Main Process ------------
need_sudo

msg "RISC-V Ubuntu Base Image Verification"
msg "====================================="

# Check if base image exists
check_base_image

# Check if SSH port is available
check_port_available "$SSH_PORT"

# Show VM information
show_vm_info

case "$TEST_MODE" in
  "interactive"|"i")
    msg "Starting interactive test mode..."
    boot_vm_interactive
    ;;
  "auto"|"a")
    msg "Starting automated test mode..."
    if boot_vm_auto_test; then
      msg "✅ Automated test PASSED"
    else
      err "❌ Automated test FAILED"
      exit 1
    fi
    ;;
  "basic"|"b")
    msg "Starting basic boot test..."
    if boot_vm_basic_test; then
      msg "✅ Basic boot test PASSED"
    else
      err "❌ Basic boot test FAILED"
      exit 1
    fi
    ;;
  *)
    err "Unknown test mode: $TEST_MODE"
    err "Usage: $0 [interactive|auto|basic]"
    err "  interactive - Manual testing with console access"
    err "  auto        - Automated testing with expect (requires expect package)"
    err "  basic       - Basic boot test without interaction"
    exit 1
    ;;
esac

msg "Test completed successfully!"