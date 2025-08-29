#!/usr/bin/env bash

# 안전한 chroot 클린업 스크립트
# 비정상 종료된 chroot 환경들을 안전하게 정리

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

echo "=== SAFE CHROOT CLEANUP ==="

# 활성 schroot 세션 강제 종료
echo "Terminating active schroot sessions..."
sudo schroot --end-session --all-sessions 2>/dev/null || true

# 임시 chroot 디렉토리들 찾기
TEMP_CHROOTS=$(find /srv/chroot -maxdepth 1 -name "${REL}-${ARCH}-build-*" -type d 2>/dev/null || true)

if [ -z "$TEMP_CHROOTS" ]; then
    echo "✅ No temporary chroots found"
    exit 0
fi

echo "Found temporary chroots to clean:"
echo "$TEMP_CHROOTS"
echo ""

for TEMP_CHROOT in $TEMP_CHROOTS; do
    CHROOT_NAME=$(basename "$TEMP_CHROOT")
    echo "🧹 Cleaning up: $CHROOT_NAME"
    
    # 1. schroot 설정 파일 제거
    sudo rm -f "/etc/schroot/chroot.d/${CHROOT_NAME}"
    
    # 2. 마운트된 파일시스템 안전하게 해제
    echo "  Unmounting filesystems..."
    
    # schroot-listmounts로 마운트 목록 가져오기
    LIBEXEC_DIR="/usr/lib/x86_64-linux-gnu/schroot"
    MOUNTS=$(sudo "$LIBEXEC_DIR/schroot-listmounts" -m "$TEMP_CHROOT" 2>/dev/null || true)
    
    if [ -n "$MOUNTS" ]; then
        echo "    Found mounts to unmount:"
        echo "$MOUNTS" | sed 's/^/      /'
        
        # 역순으로 마운트 해제 (깊은 것부터)
        echo "$MOUNTS" | tac | while read MOUNTLOC; do
            if [ -n "$MOUNTLOC" ]; then
                echo "    Unmounting: $MOUNTLOC"
                sudo umount "$MOUNTLOC" 2>/dev/null || {
                    echo "    ⚠️  Failed to unmount $MOUNTLOC, trying lazy unmount..."
                    sudo umount -l "$MOUNTLOC" 2>/dev/null || {
                        echo "    ❌ Failed to unmount $MOUNTLOC"
                    }
                }
            fi
        done
    else
        echo "    No mounts found"
    fi
    
    # 3. 잠시 대기 (마운트 해제 완료 확인)
    sleep 1
    
    # 4. 디렉토리 제거
    echo "  Removing chroot directory..."
    if sudo rm -rf "$TEMP_CHROOT" 2>/dev/null; then
        echo "  ✅ Successfully removed: $CHROOT_NAME"
    else
        echo "  ❌ Failed to remove: $CHROOT_NAME (may still have active mounts)"
        
        # 잔여 마운트 확인
        REMAINING=$(mount | grep "$TEMP_CHROOT" || true)
        if [ -n "$REMAINING" ]; then
            echo "  Remaining mounts:"
            echo "$REMAINING" | sed 's/^/    /'
        fi
    fi
    
    echo ""
done

# 5. 작업 디렉토리 정리
if [ -d "${BASE_DIR}/work" ]; then
    echo "🧹 Cleaning work directory..."
    rm -rf "${BASE_DIR}/work" 2>/dev/null || true
fi

echo "=== CLEANUP COMPLETED ==="
echo ""
echo "💡 If you see remaining mount errors, reboot the system to"
echo "   ensure all temporary mounts are properly cleared."