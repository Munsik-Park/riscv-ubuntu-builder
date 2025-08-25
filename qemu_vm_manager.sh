#!/usr/bin/env bash
# qemu_vm_manager.sh  
# Manage QEMU VMs for package builds
# Usage: ./qemu_vm_manager.sh <command> [args]

set -euo pipefail

VM_BASE_DIR="${VM_BASE_DIR:-/srv/qemu-vms}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ------------ Helpers ------------
msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

show_usage() {
    cat << EOF
Usage: $0 <command> [args]

Commands:
  list                    - List all VM images
  status                  - Show VM status  
  start <package>         - Start VM for package
  stop <package>          - Stop VM for package
  connect <package>       - SSH to VM
  console <package>       - Show VM console log
  clean <package>         - Remove VM image
  clean-all              - Remove all VM images
  build <package>         - Full build: create VM + build package
  
Examples:
  $0 list
  $0 start tar
  $0 connect tar  
  $0 build binutils
  $0 clean tar

Environment variables:
  VM_BASE_DIR     - Base directory for VMs (default: /srv/qemu-vms)
EOF
}

get_vm_info() {
    local package="$1"
    local vm_dir="$VM_BASE_DIR/$package"
    local config_file="$vm_dir/vm-config.json"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    # Extract info from config (basic parsing without jq dependency)
    local ssh_port=$(grep '"ssh_port"' "$config_file" | sed 's/.*: *\([0-9]*\).*/\1/')
    local memory=$(grep '"memory"' "$config_file" | sed 's/.*: *\([0-9]*\).*/\1/')
    local cpus=$(grep '"cpus"' "$config_file" | sed 's/.*: *\([0-9]*\).*/\1/')
    
    echo "$ssh_port,$memory,$cpus"
}

is_vm_running() {
    local package="$1"
    local vm_info
    
    if ! vm_info=$(get_vm_info "$package"); then
        return 1
    fi
    
    local ssh_port=$(echo "$vm_info" | cut -d',' -f1)
    
    # Check if SSH port is open
    if nc -z localhost "$ssh_port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

list_vms() {
    msg "Available VM images:"
    echo
    printf "%-15s %-8s %-8s %-8s %-12s %s\n" "PACKAGE" "STATUS" "SSH_PORT" "MEMORY" "CPUS" "CREATED"
    echo "--------------------------------------------------------------------------------"
    
    if [[ ! -d "$VM_BASE_DIR" ]]; then
        warn "No VM base directory found: $VM_BASE_DIR"
        return 0
    fi
    
    for vm_dir in "$VM_BASE_DIR"/*; do
        if [[ -d "$vm_dir" ]]; then
            local package=$(basename "$vm_dir")
            local config_file="$vm_dir/vm-config.json"
            
            if [[ -f "$config_file" ]]; then
                local vm_info
                if vm_info=$(get_vm_info "$package"); then
                    local ssh_port=$(echo "$vm_info" | cut -d',' -f1)
                    local memory=$(echo "$vm_info" | cut -d',' -f2)
                    local cpus=$(echo "$vm_info" | cut -d',' -f3)
                    local status
                    
                    if is_vm_running "$package"; then
                        status="\033[1;32mRUNNING\033[0m"
                    else
                        status="STOPPED"
                    fi
                    
                    local created=$(grep '"created"' "$config_file" | sed 's/.*": *"\([^"]*\)".*/\1/' | cut -d'T' -f1)
                    
                    printf "%-15s %-16s %-8s %-8s %-8s %s\n" "$package" "$status" "$ssh_port" "${memory}MB" "$cpus" "$created"
                else
                    printf "%-15s %-8s %-8s %-8s %-8s %s\n" "$package" "ERROR" "-" "-" "-" "-"
                fi
            else
                printf "%-15s %-8s %-8s %-8s %-8s %s\n" "$package" "PARTIAL" "-" "-" "-" "-"
            fi
        fi
    done
}

show_status() {
    msg "VM Status Summary:"
    echo
    
    local total=0
    local running=0
    local stopped=0
    
    if [[ -d "$VM_BASE_DIR" ]]; then
        for vm_dir in "$VM_BASE_DIR"/*; do
            if [[ -d "$vm_dir" ]] && [[ -f "$vm_dir/vm-config.json" ]]; then
                local package=$(basename "$vm_dir")
                ((total++))
                
                if is_vm_running "$package"; then
                    ((running++))
                else
                    ((stopped++))
                fi
            fi
        done
    fi
    
    echo "Total VMs: $total"
    echo "Running: $running"
    echo "Stopped: $stopped"
    echo "VM base directory: $VM_BASE_DIR"
    
    if [[ $total -gt 0 ]]; then
        echo
        list_vms
    fi
}

start_vm() {
    local package="$1"
    local vm_dir="$VM_BASE_DIR/$package"
    
    if [[ ! -d "$vm_dir" ]]; then
        err "VM not found for package: $package"
        err "Create it with: sudo ./build_qemu_vm_image.sh $package"
        return 1
    fi
    
    if is_vm_running "$package"; then
        warn "VM already running for package: $package"
        return 0
    fi
    
    msg "Starting VM for package: $package"
    cd "$vm_dir"
    
    # Start VM in background
    nohup ./start-vm.sh > vm-console.log 2>&1 &
    local vm_pid=$!
    
    echo "$vm_pid" > vm.pid
    msg "VM started with PID: $vm_pid"
    
    # Wait for SSH to become available
    local vm_info
    vm_info=$(get_vm_info "$package")
    local ssh_port=$(echo "$vm_info" | cut -d',' -f1)
    
    msg "Waiting for SSH on port $ssh_port..."
    local count=0
    while [[ $count -lt 60 ]]; do
        if nc -z localhost "$ssh_port" 2>/dev/null; then
            msg "VM ready! SSH port: $ssh_port"
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    err "VM failed to become ready within 60 seconds"
    return 1
}

stop_vm() {
    local package="$1"
    local vm_dir="$VM_BASE_DIR/$package"
    
    if [[ ! -d "$vm_dir" ]]; then
        err "VM not found for package: $package"
        return 1
    fi
    
    if ! is_vm_running "$package"; then
        warn "VM not running for package: $package"
        return 0
    fi
    
    msg "Stopping VM for package: $package"
    
    # Try graceful shutdown via SSH
    local vm_info
    vm_info=$(get_vm_info "$package")
    local ssh_port=$(echo "$vm_info" | cut -d',' -f1)
    
    ssh $SSH_OPTS -p "$ssh_port" builder@localhost "sudo shutdown -h now" 2>/dev/null || true
    
    # Wait for shutdown
    local count=0
    while [[ $count -lt 30 ]] && is_vm_running "$package"; do
        sleep 1
        ((count++))
    done
    
    # Force kill if still running
    if [[ -f "$vm_dir/vm.pid" ]]; then
        local vm_pid=$(cat "$vm_dir/vm.pid")
        if kill -0 "$vm_pid" 2>/dev/null; then
            warn "Force killing VM process: $vm_pid"
            kill -TERM "$vm_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$vm_pid" 2>/dev/null || true
        fi
        rm -f "$vm_dir/vm.pid"
    fi
    
    msg "VM stopped for package: $package"
}

connect_vm() {
    local package="$1"
    
    if ! is_vm_running "$package"; then
        err "VM not running for package: $package"
        err "Start it with: $0 start $package"
        return 1
    fi
    
    local vm_info
    vm_info=$(get_vm_info "$package")
    local ssh_port=$(echo "$vm_info" | cut -d',' -f1)
    
    msg "Connecting to VM for package: $package (port $ssh_port)"
    msg "Login as 'builder' (password: builder) or 'root' (password: root)"
    
    ssh $SSH_OPTS -p "$ssh_port" builder@localhost
}

show_console() {
    local package="$1"
    local vm_dir="$VM_BASE_DIR/$package"
    local console_log="$vm_dir/vm-console.log"
    
    if [[ ! -f "$console_log" ]]; then
        err "Console log not found: $console_log"
        return 1
    fi
    
    msg "VM console log for $package:"
    echo "=========================="
    tail -50 "$console_log"
}

clean_vm() {
    local package="$1"
    local vm_dir="$VM_BASE_DIR/$package"
    
    if [[ ! -d "$vm_dir" ]]; then
        warn "VM not found for package: $package"
        return 0
    fi
    
    # Stop VM if running
    if is_vm_running "$package"; then
        msg "Stopping running VM..."
        stop_vm "$package"
    fi
    
    # Remove VM directory
    msg "Removing VM for package: $package"
    rm -rf "$vm_dir"
    msg "VM removed: $package"
}

clean_all_vms() {
    msg "Removing all VMs..."
    
    if [[ ! -d "$VM_BASE_DIR" ]]; then
        msg "No VMs found"
        return 0
    fi
    
    for vm_dir in "$VM_BASE_DIR"/*; do
        if [[ -d "$vm_dir" ]]; then
            local package=$(basename "$vm_dir")
            clean_vm "$package"
        fi
    done
    
    rmdir "$VM_BASE_DIR" 2>/dev/null || true
    msg "All VMs removed"
}

full_build() {
    local package="$1"
    
    msg "Full build for package: $package"
    msg "Step 1/2: Creating VM image..."
    
    if ! sudo ./build_qemu_vm_image.sh "$package"; then
        err "Failed to create VM image"
        return 1
    fi
    
    msg "Step 2/2: Building package in VM..."
    
    if ! ./build_in_qemu_vm.sh "$package"; then
        err "Failed to build package in VM"
        return 1
    fi
    
    msg "Full build completed for package: $package"
}

# ------------ Main Command Processing ------------

case "${1:-}" in
    list)
        list_vms
        ;;
    status)
        show_status
        ;;
    start)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        start_vm "$2"
        ;;
    stop)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        stop_vm "$2"
        ;;
    connect)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        connect_vm "$2"
        ;;
    console)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        show_console "$2"
        ;;
    clean)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        clean_vm "$2"
        ;;
    clean-all)
        clean_all_vms
        ;;
    build)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        full_build "$2"
        ;;
    -h|--help|help|"")
        show_usage
        ;;
    *)
        err "Unknown command: ${1}"
        show_usage
        exit 1
        ;;
esac