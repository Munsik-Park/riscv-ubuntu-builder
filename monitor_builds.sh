#!/usr/bin/env bash
# monitor_builds.sh
# Monitor parallel RISC-V package builds in real-time
#
# Usage:
#   ./monitor_builds.sh [command]
#
# Commands:
#   status     - Show current build status
#   logs       - Tail all build logs
#   errors     - Show only errors from all builds
#   package    - Monitor specific package (interactive)
#

set -euo pipefail

BUILD_BASE_DIR="${BUILD_BASE_DIR:-/srv}"

msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

show_status() {
    echo "========================================"
    echo "Current Build Status"
    echo "========================================"
    
    for build_dir in $BUILD_BASE_DIR/rvbuild-*; do
        if [[ ! -d "$build_dir" ]]; then
            continue
        fi
        
        local pkg=$(basename "$build_dir" | sed 's/^rvbuild-//')
        local status="UNKNOWN"
        local progress=""
        
        # Check if build process is running
        if pgrep -f "build_single_package.sh.*$pkg" >/dev/null 2>&1; then
            status="RUNNING"
            # Try to get progress from log
            if [[ -f "$build_dir/logs/20_build_$pkg.log" ]]; then
                local last_line=$(tail -n 1 "$build_dir/logs/20_build_$pkg.log" 2>/dev/null || echo "")
                if [[ -n "$last_line" ]]; then
                    progress=" - $(echo "$last_line" | cut -c1-60)..."
                fi
            fi
        elif [[ -d "$build_dir/out/$pkg" && $(find "$build_dir/out/$pkg" -name "*.deb" 2>/dev/null | wc -l) -gt 0 ]]; then
            status="SUCCESS"
            local deb_count=$(find "$build_dir/out/$pkg" -name "*.deb" 2>/dev/null | wc -l)
            progress=" - $deb_count packages built"
        elif [[ -f "$build_dir/logs/20_build_$pkg.log" ]]; then
            local log_file="$build_dir/logs/20_build_$pkg.log"
            if grep -q "dpkg-buildpackage.*error" "$log_file" 2>/dev/null || 
               grep -q "make.*Error" "$log_file" 2>/dev/null ||
               grep -q "configure.*failed" "$log_file" 2>/dev/null; then
                status="FAILED"
                progress=" - Check $build_dir/logs/"
            else
                status="BUILDING"
            fi
        elif [[ -d "$build_dir" ]]; then
            status="PREPARED"
        fi
        
        printf "%-20s %-10s %s\n" "$pkg" "$status" "$progress"
    done
    echo "========================================"
}

tail_logs() {
    msg "Tailing all build logs (Ctrl+C to stop)..."
    echo "========================================"
    
    # Find all active build logs
    local log_files=()
    for build_dir in $BUILD_BASE_DIR/rvbuild-*; do
        if [[ -d "$build_dir/logs" ]]; then
            local pkg=$(basename "$build_dir" | sed 's/^rvbuild-//')
            local log_file="$build_dir/logs/20_build_$pkg.log"
            if [[ -f "$log_file" ]]; then
                log_files+=("$log_file")
            fi
        fi
    done
    
    if [[ ${#log_files[@]} -eq 0 ]]; then
        warn "No build logs found"
        return 1
    fi
    
    # Use tail with multiple files
    tail -f "${log_files[@]}" | while IFS= read -r line; do
        # Add timestamp and color coding
        if [[ "$line" =~ ==\>.*\.log ]]; then
            # File header from tail -f
            echo -e "\033[1;34m$line\033[0m"
        elif [[ "$line" =~ [Ee]rror|[Ff]ailed|[Ff]atal ]]; then
            # Error lines in red
            echo -e "\033[1;31m$(date +'%H:%M:%S') $line\033[0m"
        elif [[ "$line" =~ [Ww]arning ]]; then
            # Warning lines in yellow
            echo -e "\033[1;33m$(date +'%H:%M:%S') $line\033[0m"
        elif [[ "$line" =~ gcc.*-c.*\.c ]]; then
            # Compilation lines in green
            echo -e "\033[1;32m$(date +'%H:%M:%S') $line\033[0m"
        else
            # Normal lines
            echo "$(date +'%H:%M:%S') $line"
        fi
    done
}

show_errors() {
    echo "========================================"
    echo "Recent Errors from All Builds"
    echo "========================================"
    
    for build_dir in $BUILD_BASE_DIR/rvbuild-*; do
        if [[ ! -d "$build_dir/logs" ]]; then
            continue
        fi
        
        local pkg=$(basename "$build_dir" | sed 's/^rvbuild-//')
        local log_file="$build_dir/logs/20_build_$pkg.log"
        
        if [[ -f "$log_file" ]]; then
            echo ""
            echo -e "\033[1;34m=== $pkg ===\033[0m"
            
            # Extract errors and important messages
            grep -i -E "(error|failed|fatal|cannot|unable|not found)" "$log_file" | tail -n 5 | while IFS= read -r line; do
                echo -e "\033[1;31m$line\033[0m"
            done
            
            # If no errors, show the last few lines
            if ! grep -qi -E "(error|failed|fatal)" "$log_file"; then
                echo -e "\033[1;32mNo errors found. Last few lines:\033[0m"
                tail -n 3 "$log_file" | while IFS= read -r line; do
                    echo "  $line"
                done
            fi
        fi
    done
    echo "========================================"
}

monitor_package() {
    echo "Available packages:"
    for build_dir in $BUILD_BASE_DIR/rvbuild-*; do
        if [[ -d "$build_dir" ]]; then
            local pkg=$(basename "$build_dir" | sed 's/^rvbuild-//')
            echo "  $pkg"
        fi
    done
    
    read -p "Enter package name to monitor: " pkg_name
    
    local build_dir="$BUILD_BASE_DIR/rvbuild-$pkg_name"
    local log_file="$build_dir/logs/20_build_$pkg_name.log"
    
    if [[ ! -d "$build_dir" ]]; then
        err "Package build directory not found: $build_dir"
        exit 1
    fi
    
    if [[ ! -f "$log_file" ]]; then
        warn "Log file not yet created: $log_file"
        echo "Waiting for build to start..."
        while [[ ! -f "$log_file" ]]; do
            sleep 1
        done
    fi
    
    msg "Monitoring $pkg_name build log..."
    tail -f "$log_file"
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
    *)
        echo "Usage: $0 [status|logs|errors|package]"
        echo ""
        echo "Commands:"
        echo "  status   - Show current build status (default)"
        echo "  logs     - Tail all build logs in real-time"
        echo "  errors   - Show recent errors from all builds"
        echo "  package  - Monitor specific package build"
        exit 1
        ;;
esac