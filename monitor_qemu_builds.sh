#!/usr/bin/env bash
# monitor_qemu_builds.sh
# Monitor QEMU RISC-V package builds in real-time
#
# Usage:
#   ./monitor_qemu_builds.sh [command]
#
# Commands:
#   status     - Show current QEMU build status (default)
#   logs       - Tail all QEMU build logs
#   errors     - Show only errors from all QEMU builds
#   package    - Monitor specific package (interactive)
#   summary    - Show build summary with timing
#   resources  - Show system resource usage

set -euo pipefail

QEMU_BASE_DIR="${QEMU_BASE_DIR:-/srv/qemu-builds}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_LIST_FILE="${PACKAGE_LIST_FILE:-$SCRIPT_DIR/build_packages.list}"

msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

load_packages() {
    if [[ ! -f "$PACKAGE_LIST_FILE" ]]; then
        echo "binutils iputils-ping openssh-server coreutils tar"
        return
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" ]] && continue
        echo "$line"
    done < "$PACKAGE_LIST_FILE"
}

get_build_status() {
    local pkg="$1"
    local build_dir="$QEMU_BASE_DIR/$pkg"
    local log_file="$build_dir/build.log"
    local out_dir="$build_dir/out"
    
    # Check if QEMU build process is running
    if pgrep -f "build_qemu_single.sh $pkg" >/dev/null 2>&1; then
        echo "RUNNING"
        return
    fi
    
    # Check for successful completion
    if [[ -d "$out_dir" ]] && [[ -n "$(find "$out_dir" -name "*.deb" 2>/dev/null)" ]]; then
        echo "SUCCESS"
        return
    fi
    
    # Check for failure indicators in log
    if [[ -f "$log_file" ]]; then
        if grep -qi -E "(error|failed|fatal|cannot|unable)" "$log_file" 2>/dev/null; then
            # Check if it's actually completed successfully despite errors
            if tail -n 10 "$log_file" 2>/dev/null | grep -q "Build completed.*successfully"; then
                echo "SUCCESS"
            else
                echo "FAILED"
            fi
        else
            # Log exists but no clear failure - might be building or completed
            if tail -n 5 "$log_file" 2>/dev/null | grep -q "completed successfully\|dpkg-buildpackage.*info"; then
                echo "SUCCESS"
            else
                echo "BUILDING"
            fi
        fi
        return
    fi
    
    # Build directory exists but no log yet
    if [[ -d "$build_dir" ]]; then
        echo "PREPARED"
        return
    fi
    
    echo "PENDING"
}

get_progress_info() {
    local pkg="$1"
    local status="$2"
    local build_dir="$QEMU_BASE_DIR/$pkg"
    local log_file="$build_dir/build.log"
    local out_dir="$build_dir/out"
    
    case "$status" in
        "SUCCESS")
            if [[ -d "$out_dir" ]]; then
                local deb_count=$(find "$out_dir" -name "*.deb" 2>/dev/null | wc -l)
                echo "$deb_count packages built"
            else
                echo "completed"
            fi
            ;;
        "RUNNING"|"BUILDING")
            if [[ -f "$log_file" ]]; then
                local last_line=$(tail -n 1 "$log_file" 2>/dev/null | cut -c1-50)
                if [[ -n "$last_line" ]]; then
                    echo "$last_line..."
                else
                    echo "in progress"
                fi
            else
                echo "starting up"
            fi
            ;;
        "FAILED")
            echo "check $build_dir/build.log"
            ;;
        "PREPARED")
            echo "environment ready"
            ;;
        "PENDING")
            echo "not started"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

get_build_time() {
    local pkg="$1"
    local build_dir="$QEMU_BASE_DIR/$pkg"
    local log_file="$build_dir/build.log"
    
    if [[ -f "$log_file" ]]; then
        local start_time=$(stat -c %Y "$log_file" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        local duration=$((current_time - start_time))
        
        if [[ $duration -gt 0 ]]; then
            if [[ $duration -lt 60 ]]; then
                echo "${duration}s"
            elif [[ $duration -lt 3600 ]]; then
                echo "$((duration / 60))m"
            else
                echo "$((duration / 3600))h$((duration % 3600 / 60))m"
            fi
        else
            echo "-"
        fi
    else
        echo "-"
    fi
}

show_status() {
    echo "========================================"
    echo "QEMU Build Status - $(date)"
    echo "========================================"
    printf "%-15s %-10s %-8s %s\n" "PACKAGE" "STATUS" "TIME" "PROGRESS"
    echo "----------------------------------------"
    
    local packages=($(load_packages))
    local total=${#packages[@]}
    local success=0
    local running=0
    local failed=0
    local pending=0
    
    for pkg in "${packages[@]}"; do
        local status=$(get_build_status "$pkg")
        local progress=$(get_progress_info "$pkg" "$status")
        local build_time=$(get_build_time "$pkg")
        
        # Color coding for status
        local status_colored
        case "$status" in
            "SUCCESS") status_colored="\033[1;32m$status\033[0m"; ((success++)) ;;
            "RUNNING") status_colored="\033[1;34m$status\033[0m"; ((running++)) ;;
            "FAILED") status_colored="\033[1;31m$status\033[0m"; ((failed++)) ;;
            "BUILDING") status_colored="\033[1;36m$status\033[0m"; ((running++)) ;;
            *) status_colored="$status"; ((pending++)) ;;
        esac
        
        printf "%-15s %-18s %-8s %s\n" "$pkg" "$status_colored" "$build_time" "$progress"
    done
    
    echo "========================================"
    printf "Total: %d | " "$total"
    printf "\033[1;32mSuccess: %d\033[0m | " "$success"
    printf "\033[1;34mRunning: %d\033[0m | " "$running"
    printf "\033[1;31mFailed: %d\033[0m | " "$failed"
    printf "Pending: %d\n" "$pending"
    echo "========================================"
}

tail_logs() {
    msg "Tailing all QEMU build logs (Ctrl+C to stop)..."
    echo "========================================"
    
    local log_files=()
    local packages=($(load_packages))
    
    for pkg in "${packages[@]}"; do
        local log_file="$QEMU_BASE_DIR/$pkg/build.log"
        if [[ -f "$log_file" ]]; then
            log_files+=("$log_file")
        fi
    done
    
    if [[ ${#log_files[@]} -eq 0 ]]; then
        warn "No QEMU build logs found in $QEMU_BASE_DIR"
        return 1
    fi
    
    # Use tail with multiple files
    tail -f "${log_files[@]}" 2>/dev/null | while IFS= read -r line; do
        # Add timestamp and color coding
        if [[ "$line" =~ ==\>.*build\.log ]]; then
            # Extract package name from log file path
            local pkg_name=$(echo "$line" | sed 's/.*qemu-builds\/\([^/]*\)\/build\.log.*/\1/')
            echo -e "\033[1;34m[$pkg_name] $line\033[0m"
        elif [[ "$line" =~ [Ee]rror|[Ff]ailed|[Ff]atal|cannot|unable ]]; then
            echo -e "\033[1;31m$(date +'%H:%M:%S') $line\033[0m"
        elif [[ "$line" =~ [Ww]arning ]]; then
            echo -e "\033[1;33m$(date +'%H:%M:%S') $line\033[0m"
        elif [[ "$line" =~ (gcc|dpkg-buildpackage|make.*-j) ]]; then
            echo -e "\033[1;32m$(date +'%H:%M:%S') $line\033[0m"
        elif [[ "$line" =~ (completed successfully|Build completed) ]]; then
            echo -e "\033[1;32m$(date +'%H:%M:%S') ✅ $line\033[0m"
        else
            echo "$(date +'%H:%M:%S') $line"
        fi
    done
}

show_errors() {
    echo "========================================"
    echo "Recent Errors from All QEMU Builds"
    echo "========================================"
    
    local packages=($(load_packages))
    
    for pkg in "${packages[@]}"; do
        local build_dir="$QEMU_BASE_DIR/$pkg"
        local log_file="$build_dir/build.log"
        
        if [[ ! -f "$log_file" ]]; then
            continue
        fi
        
        echo ""
        echo -e "\033[1;34m=== $pkg ===\033[0m"
        
        # Extract errors and important messages
        local error_lines=$(grep -i -E "(error|failed|fatal|cannot|unable)" "$log_file" 2>/dev/null | tail -n 5)
        
        if [[ -n "$error_lines" ]]; then
            echo "$error_lines" | while IFS= read -r line; do
                echo -e "\033[1;31m$line\033[0m"
            done
        else
            echo -e "\033[1;32mNo errors found. Last few lines:\033[0m"
            tail -n 3 "$log_file" 2>/dev/null | while IFS= read -r line; do
                echo "  $line"
            done
        fi
    done
    echo "========================================"
}

monitor_package() {
    local packages=($(load_packages))
    
    echo "Available QEMU builds:"
    for pkg in "${packages[@]}"; do
        local status=$(get_build_status "$pkg")
        printf "  %-15s (%s)\n" "$pkg" "$status"
    done
    echo
    
    read -p "Enter package name to monitor: " pkg_name
    
    # Validate package name
    local valid=false
    for pkg in "${packages[@]}"; do
        if [[ "$pkg" == "$pkg_name" ]]; then
            valid=true
            break
        fi
    done
    
    if [[ "$valid" != "true" ]]; then
        err "Invalid package name: $pkg_name"
        exit 1
    fi
    
    local build_dir="$QEMU_BASE_DIR/$pkg_name"
    local log_file="$build_dir/build.log"
    
    if [[ ! -d "$build_dir" ]]; then
        err "QEMU build directory not found: $build_dir"
        exit 1
    fi
    
    if [[ ! -f "$log_file" ]]; then
        warn "Log file not yet created: $log_file"
        echo "Waiting for QEMU build to start..."
        local waited=0
        while [[ ! -f "$log_file" && $waited -lt 30 ]]; do
            sleep 1
            ((waited++))
        done
        
        if [[ ! -f "$log_file" ]]; then
            err "Log file still not found after 30 seconds"
            exit 1
        fi
    fi
    
    msg "Monitoring $pkg_name QEMU build log..."
    echo "Build directory: $build_dir"
    echo "========================================"
    tail -f "$log_file"
}

show_summary() {
    echo "========================================"
    echo "QEMU Build Summary"
    echo "========================================"
    
    local packages=($(load_packages))
    local total_time=0
    
    printf "%-15s %-10s %-8s %-12s %s\n" "PACKAGE" "STATUS" "TIME" "DEB_COUNT" "SIZE"
    echo "----------------------------------------------------------------"
    
    for pkg in "${packages[@]}"; do
        local status=$(get_build_status "$pkg")
        local build_time=$(get_build_time "$pkg")
        local build_dir="$QEMU_BASE_DIR/$pkg"
        local out_dir="$build_dir/out"
        
        local deb_count="-"
        local total_size="-"
        
        if [[ -d "$out_dir" ]]; then
            deb_count=$(find "$out_dir" -name "*.deb" 2>/dev/null | wc -l)
            if [[ $deb_count -gt 0 ]]; then
                total_size=$(du -sh "$out_dir" 2>/dev/null | cut -f1)
            fi
        fi
        
        printf "%-15s %-10s %-8s %-12s %s\n" "$pkg" "$status" "$build_time" "$deb_count" "$total_size"
    done
    
    echo "========================================"
    echo "Build artifacts location: $QEMU_BASE_DIR"
}

show_resources() {
    echo "========================================"
    echo "System Resources - QEMU Builds"
    echo "========================================"
    
    # Show CPU and memory usage
    echo "CPU Usage:"
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print "  Idle: " $1 "% (Used: " (100 - $1) "%)"}'
    
    echo
    echo "Memory Usage:"
    free -h | grep "Mem:" | awk '{print "  Total: " $2 ", Used: " $3 " (" $3/$2*100 "%), Available: " $7}'
    
    echo
    echo "Disk Usage for QEMU builds:"
    if [[ -d "$QEMU_BASE_DIR" ]]; then
        du -sh "$QEMU_BASE_DIR" 2>/dev/null || echo "  $QEMU_BASE_DIR not found"
        echo
        echo "Per-package disk usage:"
        for pkg_dir in "$QEMU_BASE_DIR"/*; do
            if [[ -d "$pkg_dir" ]]; then
                local pkg=$(basename "$pkg_dir")
                local size=$(du -sh "$pkg_dir" 2>/dev/null | cut -f1)
                printf "  %-15s %s\n" "$pkg:" "$size"
            fi
        done
    else
        echo "  $QEMU_BASE_DIR not found"
    fi
    
    echo
    echo "Active QEMU processes:"
    local qemu_count=$(pgrep -f "build_qemu_single.sh" | wc -l)
    echo "  Running builds: $qemu_count"
    if [[ $qemu_count -gt 0 ]]; then
        echo "  Process details:"
        pgrep -f "build_qemu_single.sh" | while read pid; do
            local cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null | cut -c1-60)
            echo "    PID $pid: $cmd..."
        done
    fi
    echo "========================================"
}

# Main command handling
case "${1:-status}" in
    status)
        show_status
        ;;
    logs)
        tail_logs
        ;;
    errors)
        show_errors
        ;;
    package)
        monitor_package
        ;;
    summary)
        show_summary
        ;;
    resources)
        show_resources
        ;;
    *)
        echo "Usage: $0 [status|logs|errors|package|summary|resources]"
        echo ""
        echo "Commands:"
        echo "  status     - Show current QEMU build status (default)"
        echo "  logs       - Tail all QEMU build logs in real-time"
        echo "  errors     - Show recent errors from all QEMU builds"
        echo "  package    - Monitor specific package build"
        echo "  summary    - Show build summary with timing and artifacts"
        echo "  resources  - Show system resource usage"
        echo ""
        echo "Environment variables:"
        echo "  QEMU_BASE_DIR      - Base directory for QEMU builds (default: /srv/qemu-builds)"
        echo "  PACKAGE_LIST_FILE  - Package list file (default: ./build_packages.list)"
        exit 1
        ;;
esac