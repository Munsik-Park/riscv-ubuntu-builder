#!/usr/bin/env bash
# manage_packages.sh
# 빌드 패키지 목록 관리 도구

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_LIST_FILE="${PACKAGE_LIST_FILE:-$SCRIPT_DIR/build_packages.list}"

msg() { echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
err() { echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m" >&2; }

show_usage() {
    cat << EOF
Usage: $0 <command> [arguments]

Commands:
  list                    - 현재 빌드 패키지 목록 표시
  add <package>          - 패키지 추가
  remove <package>       - 패키지 제거
  validate               - 패키지 목록 유효성 검사
  reset-original         - 초기 15개 패키지 목록으로 리셋
  reset-minimal          - 최소 필수 패키지만 남기기
  status                 - 빌드 상태 확인

Examples:
  $0 list
  $0 add vim
  $0 remove gdb
  $0 validate
EOF
}

load_current_packages() {
    if [[ ! -f "$PACKAGE_LIST_FILE" ]]; then
        err "Package list file not found: $PACKAGE_LIST_FILE"
        return 1
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

cmd_list() {
    msg "Current build packages in $PACKAGE_LIST_FILE:"
    local packages=($(load_current_packages))
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        warn "No packages found"
        return 0
    fi
    
    local i=1
    for pkg in "${packages[@]}"; do
        printf "%2d. %s\n" "$i" "$pkg"
        ((i++))
    done
    
    echo
    msg "Total: ${#packages[@]} packages"
}

cmd_add() {
    local new_package="$1"
    
    # Validate package name
    if [[ ! "$new_package" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.-]*$ ]]; then
        err "Invalid package name: '$new_package'"
        return 1
    fi
    
    # Check if already exists
    if load_current_packages | grep -q "^$new_package$"; then
        warn "Package '$new_package' already exists in the list"
        return 0
    fi
    
    # Add to file
    echo "$new_package" >> "$PACKAGE_LIST_FILE"
    msg "Added package: $new_package"
}

cmd_remove() {
    local remove_package="$1"
    
    if [[ ! -f "$PACKAGE_LIST_FILE" ]]; then
        err "Package list file not found: $PACKAGE_LIST_FILE"
        return 1
    fi
    
    # Create temporary file without the package
    local temp_file=$(mktemp)
    local found=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Keep comments and empty lines
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi
        
        # Remove leading/trailing whitespace for comparison
        local clean_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [[ "$clean_line" == "$remove_package" ]]; then
            found=true
            msg "Removed package: $remove_package"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$PACKAGE_LIST_FILE"
    
    if [[ "$found" == "true" ]]; then
        mv "$temp_file" "$PACKAGE_LIST_FILE"
    else
        rm "$temp_file"
        warn "Package '$remove_package' not found in the list"
    fi
}

cmd_validate() {
    msg "Validating package list..."
    local packages=($(load_current_packages))
    local valid_count=0
    local invalid_count=0
    
    for pkg in "${packages[@]}"; do
        if [[ "$pkg" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.-]*$ ]]; then
            ((valid_count++))
        else
            err "Invalid package name: '$pkg'"
            ((invalid_count++))
        fi
    done
    
    if [[ $invalid_count -eq 0 ]]; then
        msg "✅ All $valid_count packages are valid"
    else
        err "❌ Found $invalid_count invalid packages out of $((valid_count + invalid_count))"
        return 1
    fi
}

cmd_reset_original() {
    msg "Resetting to original 15-package list..."
    cat > "$PACKAGE_LIST_FILE" << 'EOF'
# RISC-V Ubuntu Build Package List - Original 15 packages
# 
# 초기 목표 패키지 중 chroot에 없는 패키지들만 빌드
# (bash, coreutils, grep, sed, findutils, tar, util-linux는 이미 포함)

# 네트워크 및 압축 도구
xz-utils
iproute2
netbase
ca-certificates

# 네트워크 유틸리티
iputils-ping

# 원격 접속
openssh-server

# 개발 도구
binutils
gdb
EOF
    msg "Reset to original package list (8 packages)"
}

cmd_reset_minimal() {
    msg "Resetting to minimal essential packages..."
    cat > "$PACKAGE_LIST_FILE" << 'EOF'
# RISC-V Ubuntu Build Package List - Minimal Essential
# 
# 최소한의 필수 패키지만 포함

# 개발 도구 (필수)
binutils

# 네트워크 기본 (필수)
iputils-ping
openssh-server
ca-certificates
EOF
    msg "Reset to minimal package list (4 packages)"
}

cmd_status() {
    msg "Build package status:"
    echo
    cmd_list
    echo
    
    msg "Checking build directories..."
    local packages=($(load_current_packages))
    local built_count=0
    local building_count=0
    local pending_count=0
    
    for pkg in "${packages[@]}"; do
        local build_dir="/srv/rvbuild-$pkg"
        if [[ -d "$build_dir/out" ]] && [[ -n "$(find "$build_dir/out" -name "*.deb" 2>/dev/null)" ]]; then
            echo "  ✅ $pkg (built)"
            ((built_count++))
        elif [[ -d "$build_dir" ]]; then
            echo "  🔄 $pkg (building)"
            ((building_count++))
        else
            echo "  ⏳ $pkg (pending)"
            ((pending_count++))
        fi
    done
    
    echo
    msg "Status summary: $built_count built, $building_count building, $pending_count pending"
}

# Main command processing
case "${1:-}" in
    list)
        cmd_list
        ;;
    add)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        cmd_add "$2"
        ;;
    remove)
        [[ -z "${2:-}" ]] && { err "Package name required"; show_usage; exit 1; }
        cmd_remove "$2"
        ;;
    validate)
        cmd_validate
        ;;
    reset-original)
        cmd_reset_original
        ;;
    reset-minimal)
        cmd_reset_minimal
        ;;
    status)
        cmd_status
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        err "Unknown command: ${1:-}"
        show_usage
        exit 1
        ;;
esac