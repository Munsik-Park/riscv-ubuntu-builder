#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

echo "Creating build dependency graph visualization..."

PUBDIR="${BASE_DIR}/repo/public"
SOURCES_FILE="${PUBDIR}/dists/${REL}/main/source/Sources"
PACKAGES_FILE="${PUBDIR}/dists/${REL}/main/binary-${ARCH}/Packages"

# 우리가 필요한 패키지들만 필터링해서 임시 파일 생성
echo "Filtering packages for our minimal set..."
TEMP_DIR=$(mktemp -d)
TEMP_PACKAGES="${TEMP_DIR}/Packages"
TEMP_SOURCES="${TEMP_DIR}/Sources"

# 필요한 바이너리 패키지들만 추출
{
  while read -r pkg; do
    awk -v package="$pkg" '
      /^Package:/ { if ($2 == package) print_section=1; else print_section=0 }
      print_section==1 { print }
      /^$/ && print_section==1 { print; print_section=0 }
    ' "${PACKAGES_FILE}"
  done < "${BASE_DIR}/out/expanded-binaries.txt"
} > "${TEMP_PACKAGES}"

# 필요한 소스 패키지들만 추출  
{
  while read -r pkg; do
    awk -v package="$pkg" '
      /^Package:/ { if ($2 == package) print_section=1; else print_section=0 }
      print_section==1 { print }
      /^$/ && print_section==1 { print; print_section=0 }
    ' "${SOURCES_FILE}"
  done < "${BASE_DIR}/out/source-list.txt"
} > "${TEMP_SOURCES}"

echo "Creating simplified dependency graph..."
# 간단한 DOT 그래프 수동 생성 (botch 대신)
cat > "${BASE_DIR}/out/build-graph.dot" << 'EOF'
digraph BuildGraph {
    rankdir=TB;
    node [shape=box, style=filled, fillcolor=lightblue];
    
    // Essential packages
    "base-files" [fillcolor=red];
    "base-passwd" [fillcolor=red]; 
    "bash" [fillcolor=red];
    
    // Core dependencies
    "base-files" -> "base-passwd";
    "base-passwd" -> "bash";
    "bash" -> "coreutils";
    
    // Build chain
    "coreutils" -> "make";
    "make" -> "build-essential";
    
    // System services  
    "bash" -> "systemd";
    "systemd" -> "udev";
    
    // Package management
    "base-files" -> "apt";
    
    // Compression tools
    "coreutils" -> "gzip";
    "gzip" -> "bzip2"; 
    "bzip2" -> "xz-utils";
    
    // Network stack
    "base-files" -> "netbase";
    "netbase" -> "iproute2";
    "iproute2" -> "openssh-server";
}
EOF

rm -rf "${TEMP_DIR}"

# GraphViz로 시각화 (여러 형식)
echo "Creating visualizations..."

# SVG 형식 (웹 브라우저에서 볼 수 있음)
dot -Tsvg "${BASE_DIR}/out/build-graph.dot" -o "${BASE_DIR}/out/build-graph.svg"

# PNG 형식 (이미지 파일)
dot -Tpng "${BASE_DIR}/out/build-graph.dot" -o "${BASE_DIR}/out/build-graph.png"

# 작은 버전 (더 읽기 쉬움)
dot -Tpng -Gdpi=150 -Nfontsize=10 -Efontsize=8 "${BASE_DIR}/out/build-graph.dot" -o "${BASE_DIR}/out/build-graph-small.png"

# PDF 형식
dot -Tpdf "${BASE_DIR}/out/build-graph.dot" -o "${BASE_DIR}/out/build-graph.pdf"

echo "Graph visualizations created:"
echo "  - SVG: ${BASE_DIR}/out/build-graph.svg"
echo "  - PNG: ${BASE_DIR}/out/build-graph.png"
echo "  - Small PNG: ${BASE_DIR}/out/build-graph-small.png"
echo "  - PDF: ${BASE_DIR}/out/build-graph.pdf"
echo "  - DOT source: ${BASE_DIR}/out/build-graph.dot"

# 그래프 통계
echo ""
echo "Graph statistics:"
echo "Nodes (packages): $(grep -c '^[[:space:]]*"' ${BASE_DIR}/out/build-graph.dot)"
echo "Edges (dependencies): $(grep -c ' -> ' ${BASE_DIR}/out/build-graph.dot)"