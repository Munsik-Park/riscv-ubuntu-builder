#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

REPO="rv-${REL}-${COMP}"
WORK_DIR="${BASE_DIR}/work"

echo "Creating aptly repository: ${REPO}"
aptly -config="${BASE_DIR}/configs/aptly.conf" repo create -distribution=${REL} -component=${COMP} ${REPO} || true

echo "Starting build queue processing..."
echo "Build order file: ${BASE_DIR}/out/build-order.txt"
echo "Working directory: ${WORK_DIR}"

while read -r src; do
  echo ""
  echo "=== BUILD ${src} ==="
  
  # 작업 디렉토리 준비
  rm -rf "${WORK_DIR}" && mkdir -p "${WORK_DIR}"
  cd "${WORK_DIR}"
  
  # 소스 가져오기 (로컬 저장소에서 직접)
  echo "Fetching source files for ${src}..."
  
  # Sources 파일에서 해당 패키지의 파일들 찾기
  SOURCES_FILE="${BASE_DIR}/repo/public/dists/${REL}/main/source/Sources"
  
  # 패키지 정보 추출
  package_files=$(awk -v pkg="$src" '
    /^Package:/ { 
      if ($2 == pkg) {
        in_package = 1
        files_section = 0
      } else {
        in_package = 0
      }
    }
    /^Files:/ && in_package { files_section = 1; next }
    /^[^ ]/ && in_package && files_section { files_section = 0 }
    files_section && in_package && /^ / { 
      # Extract filename (3rd column)
      print $3
    }
  ' "$SOURCES_FILE")
  
  if [[ -z "$package_files" ]]; then
    echo "❌ Error: No source files found for ${src}"
    cd "${BASE_DIR}"
    continue
  fi
  
  # 파일들을 work 디렉토리에 복사
  echo "Copying source files:"
  for file in $package_files; do
    # 파일을 pool에서 찾기
    source_file=$(find "${BASE_DIR}/repo/public/pool" -name "$file" | head -1)
    if [[ -n "$source_file" ]]; then
      echo "  $file"
      cp "$source_file" .
    else
      echo "  ❌ $file (not found)"
    fi
  done
  
  # .dsc 파일 확인
  dsc=$(ls *.dsc | head -1)
  if [[ -z "$dsc" ]]; then
    echo "❌ Error: No .dsc file found for ${src}"
    cd "${BASE_DIR}"
    continue
  fi
  echo "Found DSC file: $dsc"
  
  # 소스 압축 해제
  dpkg-source -x "$dsc" || {
    echo "❌ Error: Failed to extract source for ${src}"
    cd "${BASE_DIR}"
    continue
  }

  # 빌드 (unshare 모드로 안전하게)
  echo "Building ${src}..."
  echo "Using unshare mode for maximum isolation..."
  if sbuild --arch=${ARCH} --dist=${REL} --chroot=${REL}-${ARCH} --chroot-mode=unshare "${dsc}"; then
    echo "✅ Build successful for ${src}"
    
    # 산출물 적재
    echo "Adding built packages to repository..."
    built_debs=$(ls ../*.deb 2>/dev/null || true)
    if [[ -n "$built_debs" ]]; then
      aptly -config="${BASE_DIR}/configs/aptly.conf" repo add ${REPO} ../*.deb || true
      
      # 저장소 업데이트 (새 패키지들을 chroot에서 사용 가능하게)
      echo "Updating repository..."
      SN="rv-${COMP}-progress-$(date +%Y%m%d-%H%M%S)"
      aptly -config="${BASE_DIR}/configs/aptly.conf" snapshot create ${SN} from repo ${REPO}
      aptly -config="${BASE_DIR}/configs/aptly.conf" publish snapshot -distribution=${REL} -component=${COMP} \
        -gpg-key="${REPO_KEY_ID}" ${SN} public || true
      
      # chroot 업데이트
      echo "Updating chroot with new packages..."
      sudo sbuild-update ${REL}-${ARCH} || true
      
      echo "✅ ${src} completed and integrated"
    else
      echo "⚠️  No .deb files found for ${src}"
    fi
    
    # 성공 시 work 디렉토리 정리
    echo "Cleaning up work directory..."
    cd "${BASE_DIR}"
    rm -rf "${WORK_DIR}"
    
  else
    echo "❌ Build failed for ${src}"
    echo "Build log should be available in: ${WORK_DIR}"
    cd "${BASE_DIR}"
    
    # 실패 시 work 디렉토리 보존하고 chroot 복구 여부 확인
    echo "Work directory preserved for debugging: ${WORK_DIR}"
    read -p "Restore clean chroot and continue? (y/N): " restore
    if [[ $restore == [yY] ]]; then
      echo "Restoring clean chroot..."
      if "${BASE_DIR}/scripts/50_manage_chroot.sh" restore; then
        echo "Cleaning up failed build..."
        rm -rf "${WORK_DIR}"
      fi
    else
      echo "Build queue stopped. Fix issues and restart."
      exit 1
    fi
  fi
done < "${BASE_DIR}/out/build-order.txt"

echo ""
echo "=== BUILD QUEUE COMPLETED ==="
echo "Final repository: ${REPO}"
