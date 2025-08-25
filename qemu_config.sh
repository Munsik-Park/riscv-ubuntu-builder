#!/usr/bin/env bash
# qemu_config.sh
# QEMU resource configuration for RISC-V builds

# QEMU VM Resource Allocation
# These values can be overridden by environment variables

# CPU Configuration
QEMU_CPUS="${QEMU_CPUS:-1}"           # Number of CPU cores per VM (default: 1)

# Memory Configuration  
QEMU_MEMORY="${QEMU_MEMORY:-8192}"    # Memory in MB per VM (default: 8GB)

# Disk Configuration
QEMU_DISK_SIZE="${QEMU_DISK_SIZE:-8G}" # Disk size per VM (default: 8GB)

# Network Configuration
QEMU_BASE_PORT="${QEMU_BASE_PORT:-2222}" # Base SSH port (incremented per VM)

# Performance Configuration
QEMU_KVM="${QEMU_KVM:-no}"            # Enable KVM (not available for RISC-V on x86_64)
QEMU_PARALLEL_JOBS="${QEMU_PARALLEL_JOBS:-1}" # make -j jobs (no parallel build)

# Display QEMU configuration
show_qemu_config() {
    echo "========================================"
    echo "QEMU VM Configuration"
    echo "========================================"
    echo "CPU Cores per VM:    $QEMU_CPUS"
    echo "Memory per VM:       ${QEMU_MEMORY}MB ($(echo "scale=1; $QEMU_MEMORY/1024" | bc)GB)"
    echo "Disk Size per VM:    $QEMU_DISK_SIZE"
    echo "Base SSH Port:       $QEMU_BASE_PORT"
    echo "Make Parallel Jobs:  $QEMU_PARALLEL_JOBS"
    echo "========================================"
}

# Calculate total resource usage for parallel builds
calculate_total_resources() {
    local max_parallel="${1:-2}"
    local total_cpus=$((QEMU_CPUS * max_parallel))
    local total_memory=$((QEMU_MEMORY * max_parallel))
    local total_memory_gb=$(echo "scale=1; $total_memory/1024" | bc)
    
    echo "========================================"
    echo "Total Resource Usage (${max_parallel} parallel VMs)"
    echo "========================================"
    echo "Total CPU Cores:     $total_cpus"
    echo "Total Memory:        ${total_memory}MB (${total_memory_gb}GB)"
    echo "Host CPU Cores:      $(nproc)"
    echo "Host Memory:         $(free -h | awk '/^Mem:/ {print $2}')"
    echo "========================================"
    
    # Resource usage warnings
    local host_cpus=$(nproc)
    local host_memory_gb=$(free -g | awk '/^Mem:/ {print $2}')
    
    if [[ $total_cpus -gt $host_cpus ]]; then
        echo "⚠️  WARNING: Total CPU allocation ($total_cpus) exceeds host CPUs ($host_cpus)"
    fi
    
    if [[ $(echo "$total_memory_gb > $host_memory_gb * 0.8" | bc) -eq 1 ]]; then
        echo "⚠️  WARNING: Memory usage (${total_memory_gb}GB) > 80% of host memory (${host_memory_gb}GB)"
    fi
}

# Get QEMU command line arguments
get_qemu_args() {
    local vm_id="${1:-1}"
    local ssh_port=$((QEMU_BASE_PORT + vm_id - 1))
    
    echo "-M virt -smp $QEMU_CPUS -m $QEMU_MEMORY"
    echo "-netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22"
    echo "-device virtio-net-device,netdev=net0"
    echo "-nographic -serial mon:stdio"
}

# Main function
main() {
    case "${1:-show}" in
        show)
            show_qemu_config
            ;;
        total)
            local parallel="${2:-2}"
            calculate_total_resources "$parallel"
            ;;
        args)
            local vm_id="${2:-1}"
            get_qemu_args "$vm_id"
            ;;
        *)
            echo "Usage: $0 [show|total|args]"
            echo ""
            echo "Commands:"
            echo "  show           - Show QEMU VM configuration"
            echo "  total <N>      - Calculate total resources for N parallel VMs"
            echo "  args <VM_ID>   - Get QEMU args for specific VM"
            echo ""
            echo "Environment variables:"
            echo "  QEMU_CPUS      - CPU cores per VM (default: 4)"
            echo "  QEMU_MEMORY    - Memory MB per VM (default: 4096)"
            echo "  QEMU_DISK_SIZE - Disk size per VM (default: 8G)"
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi