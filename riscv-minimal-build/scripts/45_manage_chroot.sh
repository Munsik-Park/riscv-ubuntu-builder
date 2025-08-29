#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

CHROOT_DIR="/srv/chroot/${REL}-${ARCH}"
BACKUP_DIR="/srv/chroot/${REL}-${ARCH}.clean"

case "$1" in
  "backup")
    if [[ -d "${CHROOT_DIR}" ]]; then
        echo "Creating clean backup..."
        sudo rm -rf "${BACKUP_DIR}"
        sudo cp -a "${CHROOT_DIR}" "${BACKUP_DIR}"
        echo "✅ Backup saved to ${BACKUP_DIR}"
        du -sh "${BACKUP_DIR}" 2>/dev/null | awk '{print "Size: " $1}'
    else
        echo "❌ Error: ${CHROOT_DIR} does not exist"
        exit 1
    fi
    ;;
    
  "restore")
    if [[ -d "${BACKUP_DIR}" ]]; then
        echo "Restoring from clean backup..."
        echo "⚠️  This will completely replace ${CHROOT_DIR}"
        read -p "Continue? (y/N): " confirm
        if [[ $confirm == [yY] ]]; then
            sudo rm -rf "${CHROOT_DIR}"
            sudo cp -a "${BACKUP_DIR}" "${CHROOT_DIR}"
            echo "✅ Chroot restored to clean state"
        else
            echo "Cancelled"
        fi
    else
        echo "❌ Error: Clean backup ${BACKUP_DIR} does not exist"
        echo "Create backup first with: $0 backup"
        exit 1
    fi
    ;;
    
  "status")
    echo "=== Chroot Status ==="
    if [[ -d "${CHROOT_DIR}" ]]; then
        echo "✅ Working chroot: ${CHROOT_DIR}"
        du -sh "${CHROOT_DIR}" 2>/dev/null | awk '{print "   Size: " $1}'
    else
        echo "❌ Working chroot: Not found"
    fi
    
    if [[ -d "${BACKUP_DIR}" ]]; then
        echo "✅ Clean backup: ${BACKUP_DIR}"  
        du -sh "${BACKUP_DIR}" 2>/dev/null | awk '{print "   Size: " $1}'
    else
        echo "❌ Clean backup: Not found"
    fi
    ;;
    
  "recreate")
    echo "Recreating chroot from scratch..."
    echo "⚠️  This will delete ${CHROOT_DIR} and recreate it"
    read -p "Continue? (y/N): " confirm
    if [[ $confirm == [yY] ]]; then
        sudo rm -rf "${CHROOT_DIR}"
        "${SCRIPT_DIR}/40_make_sbuild_chroot_native.sh"
    else
        echo "Cancelled"
    fi
    ;;
    
  *)
    echo "Usage: $0 {backup|restore|status|recreate}"
    echo ""
    echo "Commands:"
    echo "  backup   - Create clean backup of current chroot"
    echo "  restore  - Restore chroot from clean backup" 
    echo "  status   - Show status of chroot and backup"
    echo "  recreate - Delete and recreate chroot from scratch"
    echo ""
    echo "Current configuration:"
    echo "  Architecture: ${ARCH}"
    echo "  Distribution: ${REL}" 
    echo "  Chroot: ${CHROOT_DIR}"
    echo "  Backup: ${BACKUP_DIR}"
    ;;
esac