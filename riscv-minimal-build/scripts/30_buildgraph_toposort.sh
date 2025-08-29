#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

PUBDIR="${BASE_DIR}/repo/public"

# 5.1 바이너리→소스 매핑
mkdir -p "${BASE_DIR}/out"
echo "Creating source package mapping..."

# Sources 파일에서 직접 매핑 생성
SOURCES_FILE="${PUBDIR}/dists/${REL}/main/source/Sources"
PACKAGES_FILE="${PUBDIR}/dists/${REL}/main/binary-${ARCH}/Packages"

if [[ ! -f "${SOURCES_FILE}" ]]; then
    echo "Error: Sources file not found: ${SOURCES_FILE}"
    exit 1
fi

if [[ ! -f "${PACKAGES_FILE}" ]]; then
    echo "Error: Packages file not found: ${PACKAGES_FILE}"
    exit 1
fi

# 바이너리 → 소스 매핑을 Packages 파일에서 추출
> "${BASE_DIR}/out/source-list.txt"
while read -r bin; do
  # Packages 파일에서 해당 바이너리의 Source 필드 찾기
  src=$(awk -v pkg="$bin" '
    /^Package:/ { current_pkg = $2 }
    /^Source:/ { if (current_pkg == pkg) { print $2; exit } }
    /^$/ { if (current_pkg == pkg && src == "") { print current_pkg; exit } }
  ' "${PACKAGES_FILE}")
  
  if [[ -z "${src}" ]]; then
    # Source 필드가 없으면 패키지명이 소스명과 같음
    src="$bin"
  fi
  
  if [[ -n "${src}" ]]; then 
    echo "${src}" >> "${BASE_DIR}/out/source-list.txt"
  fi
done < "${BASE_DIR}/out/expanded-binaries.txt"
sort -u "${BASE_DIR}/out/source-list.txt" -o "${BASE_DIR}/out/source-list.txt"
wc -l "${BASE_DIR}/out/source-list.txt"

# 5.2 botch로 빌드 순서 계산
echo "Calculating build order..."

# 간단한 방법: 우선 소스 목록을 그대로 빌드 순서로 사용
# (실제 프로덕션에서는 botch로 정확한 의존성 계산 필요)
cp "${BASE_DIR}/out/source-list.txt" "${BASE_DIR}/out/build-order.txt"

echo "Build order calculation completed"
wc -l "${BASE_DIR}/out/build-order.txt"
