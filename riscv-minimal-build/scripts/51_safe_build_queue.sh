#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

# 실패 처리 모드 설정
FAIL_MODE=${1:-"stop"}  # stop, skip, ask

# 안전한 빌드를 위한 설정
REPO="rv-${REL}-${COMP}"
WORK_DIR="${BASE_DIR}/work"
SAFE_CHROOT_BASE="/srv/chroot/${REL}-${ARCH}.clean"

echo "=== SAFE BUILD QUEUE ==="
echo "Maximum isolation mode enabled"
echo "Each build uses a fresh chroot copy"
echo "Failure mode: ${FAIL_MODE}"
echo ""
case ${FAIL_MODE} in
  "stop") echo "Will STOP on first failure" ;;
  "skip") echo "Will SKIP failed packages and continue" ;;
  "ask")  echo "Will ASK what to do on each failure" ;;
  *) echo "Invalid mode. Use: stop, skip, ask"; exit 1 ;;
esac

# 클린 chroot 존재 확인
if [[ ! -d "${SAFE_CHROOT_BASE}" ]]; then
    echo "❌ Error: Clean chroot backup not found: ${SAFE_CHROOT_BASE}"
    echo "Run: ./scripts/50_manage_chroot.sh backup"
    exit 1
fi

while read -r src; do
  echo ""
  echo "=== SAFE BUILD: ${src} ==="
  
  # 매번 새로운 임시 chroot 생성
  TEMP_CHROOT="/srv/chroot/${REL}-${ARCH}-build-$$"
  TEMP_CHROOT_NAME="${REL}-${ARCH}-build-$$"
  
  # 비정상 종료 시 정리를 위한 trap 설정
  cleanup_on_exit() {
    echo "🚨 Script interrupted! Cleaning up..."
    sudo rm -f "/etc/schroot/chroot.d/${TEMP_CHROOT_NAME}" 2>/dev/null || true
    MOUNTS=$(sudo /usr/lib/x86_64-linux-gnu/schroot/schroot-listmounts -m "${TEMP_CHROOT}" 2>/dev/null || true)
    if [ -n "$MOUNTS" ]; then
      echo "$MOUNTS" | tac | while read MOUNTLOC; do
        [ -n "$MOUNTLOC" ] && sudo umount "$MOUNTLOC" 2>/dev/null || sudo umount -l "$MOUNTLOC" 2>/dev/null || true
      done
    fi
    sudo rm -rf "${TEMP_CHROOT}" 2>/dev/null || true
    cd "${BASE_DIR}" 2>/dev/null || true
    rm -rf "${WORK_DIR}" 2>/dev/null || true
    exit 1
  }
  trap cleanup_on_exit INT TERM EXIT
  echo "Creating isolated chroot: ${TEMP_CHROOT}"
  
  sudo cp -a "${SAFE_CHROOT_BASE}" "${TEMP_CHROOT}"
  
  # 로컬 저장소 마운트 포인트 생성
  sudo mkdir -p "${TEMP_CHROOT}/home/ubuntu/riscv-minimal-build/repo/public"
  
  # 로컬 저장소에서 바이너리 패키지도 사용할 수 있도록 sources.list 수정
  echo "deb file:///home/ubuntu/riscv-minimal-build/repo/public ${REL} ${COMP}" | sudo tee -a "${TEMP_CHROOT}/etc/apt/sources.list" > /dev/null
  
  # schroot 설정 생성
  echo "Setting up schroot configuration..."
  sudo tee "/etc/schroot/chroot.d/${TEMP_CHROOT_NAME}" > /dev/null << EOF
[${TEMP_CHROOT_NAME}]
description=Temporary build chroot
type=directory
directory=${TEMP_CHROOT}
users=root,sbuild
groups=sbuild
root-users=root,sbuild
profile=buildd
EOF
  
  # 작업 디렉토리 준비
  rm -rf "${WORK_DIR}" && mkdir -p "${WORK_DIR}"
  cd "${WORK_DIR}"
  
  # 소스 파일 가져오기 (이전과 동일)
  echo "Fetching source files for ${src}..."
  SOURCES_FILE="${BASE_DIR}/repo/public/dists/${REL}/main/source/Sources"
  
  package_files=$(awk -v pkg="$src" '
    /^Package:/ { 
      if ($2 == pkg) { in_package = 1; files_section = 0 }
      else { in_package = 0 }
    }
    /^Files:/ && in_package { files_section = 1; next }
    /^[^ ]/ && in_package && files_section { files_section = 0 }
    files_section && in_package && /^ / { print $3 }
  ' "$SOURCES_FILE")
  
  if [[ -z "$package_files" ]]; then
    echo "❌ Error: No source files found for ${src}"
    sudo rm -rf "${TEMP_CHROOT}"
    cd "${BASE_DIR}"
    continue
  fi
  
  # 소스 파일 복사
  for file in $package_files; do
    source_file=$(find "${BASE_DIR}/repo/public/pool" -name "$file" | head -1)
    if [[ -n "$source_file" ]]; then
      cp "$source_file" .
    fi
  done
  
  dsc=$(ls *.dsc | head -1)
  if [[ -z "$dsc" ]]; then
    echo "❌ Error: No .dsc file found for ${src}"
    sudo rm -rf "${TEMP_CHROOT}"
    cd "${BASE_DIR}"
    continue
  fi
  
  # GPG 서명 검증 무시하고 소스 추출
  dpkg-source --no-check -x "$dsc" || {
    echo "❌ Error: Failed to extract source for ${src}"
    sudo rm -rf "${TEMP_CHROOT}"
    cd "${BASE_DIR}"
    continue
  }
  
  # 안전한 빌드 (완전히 격리된 임시 chroot 사용)
  echo "Building ${src} in isolated environment..."
  
  if sudo sbuild --arch=${ARCH} --dist=${REL} \
                 --chroot="${TEMP_CHROOT_NAME}" \
                 --no-run-lintian \
                 "${dsc}"; then
    
    echo "✅ Build successful for ${src}"
    
    # 빌드 결과물 처리
    built_debs=$(ls ../*.deb 2>/dev/null || true)
    if [[ -n "$built_debs" ]]; then
      echo "Adding built packages to repository..."
      aptly -config="${BASE_DIR}/configs/aptly.conf" repo add ${REPO} ../*.deb || true
      
      # 저장소 업데이트
      SN="rv-${COMP}-progress-$(date +%Y%m%d-%H%M%S)"
      aptly -config="${BASE_DIR}/configs/aptly.conf" snapshot create ${SN} from repo ${REPO}
      aptly -config="${BASE_DIR}/configs/aptly.conf" publish snapshot -distribution=${REL} \
        -component=${COMP} -gpg-key="${REPO_KEY_ID}" ${SN} public || true
      
      echo "✅ ${src} completed and integrated"
    fi
  else
    echo "❌ Build failed for ${src}"
    echo ""
    echo "=== DEBUGGING INFORMATION ==="
    echo "Work directory: ${WORK_DIR}"
    echo "Temp chroot: ${TEMP_CHROOT}"
    
    # 빌드 로그 찾기
    echo ""
    echo "=== BUILD LOGS ==="
    find "${WORK_DIR}" -name "*.build" -o -name "*build-log*" -o -name "*.log" 2>/dev/null | head -5 | while read logfile; do
      echo "Log file: $logfile"
      echo "Last 20 lines:"
      tail -20 "$logfile" 2>/dev/null || echo "Cannot read log file"
      echo ""
    done
    
    # chroot에서 마지막 빌드 로그 확인
    latest_log=$(sudo find "${TEMP_CHROOT}/build" -name "*build*" -type f 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]]; then
      echo "Latest build log in chroot:"
      sudo tail -20 "$latest_log" 2>/dev/null || echo "Cannot read chroot log"
    fi
    
    # 실패 처리 모드에 따른 동작
    case ${FAIL_MODE} in
      "stop")
        echo ""
        echo "Build queue stopped due to failure."
        echo "Fix issues and restart from: ${src}"
        echo "Debug info preserved in: ${WORK_DIR}"
        echo "Temp chroot preserved in: ${TEMP_CHROOT}"
        echo ""
        echo "To clean up manually:"
        echo "  rm -rf ${WORK_DIR}"
        echo "  sudo rm -rf ${TEMP_CHROOT}"
        exit 1
        ;;
      "skip")
        echo "Skipping failed package and continuing..."
        ;;
      "ask")
        read -p "Continue building remaining packages? (y/N): " continue_build
        if [[ $continue_build != [yY] ]]; then
          echo "Build queue stopped by user."
          sudo rm -rf "${TEMP_CHROOT}"
          cd "${BASE_DIR}"
          rm -rf "${WORK_DIR}"
          exit 1
        fi
        ;;
    esac
  fi
  
  # 임시 chroot 완전 삭제 (호스트 보호)
  echo "Cleaning up isolated chroot..."
  sudo rm -f "/etc/schroot/chroot.d/${TEMP_CHROOT_NAME}"
  
  # 안전한 마운트 해제
  MOUNTS=$(sudo /usr/lib/x86_64-linux-gnu/schroot/schroot-listmounts -m "${TEMP_CHROOT}" 2>/dev/null || true)
  if [ -n "$MOUNTS" ]; then
    echo "Unmounting filesystems in ${TEMP_CHROOT}..."
    echo "$MOUNTS" | tac | while read MOUNTLOC; do
      if [ -n "$MOUNTLOC" ]; then
        sudo umount "$MOUNTLOC" 2>/dev/null || sudo umount -l "$MOUNTLOC" 2>/dev/null || true
      fi
    done
    sleep 1  # 마운트 해제 완료 대기
  fi
  
  sudo rm -rf "${TEMP_CHROOT}"
  
  cd "${BASE_DIR}"
  rm -rf "${WORK_DIR}"
  
  # trap 해제 (정상 종료)
  trap - INT TERM EXIT
  
done < "${BASE_DIR}/out/build-order.txt"

echo ""
echo "=== SAFE BUILD QUEUE COMPLETED ==="

# 사용법 정보 (파일 끝에)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo ""
  echo "Usage: $0 [mode]"
  echo "Modes:"
  echo "  stop  - Stop on first failure (default, recommended for bootstrap)"
  echo "  skip  - Skip failed packages and continue" 
  echo "  ask   - Ask what to do on each failure"
  echo ""
  echo "Examples:"
  echo "  $0           # Stop on first failure"
  echo "  $0 stop      # Same as above"
  echo "  $0 skip      # Continue even if some packages fail"
  echo "  $0 ask       # Interactive mode"
fi