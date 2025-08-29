#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

echo "Creating simple dependency visualization..."

# 간단한 DOT 그래프 생성
cat > "${BASE_DIR}/out/simple-build-graph.dot" << 'EOF'
digraph BuildOrder {
    rankdir=TB;
    node [shape=box, style=filled, fillcolor=lightblue];
    
    // Core system packages (no dependencies)
    subgraph cluster_core {
        label="Core System";
        color=red;
        "base-files" -> "base-passwd";
        "base-passwd" -> "bash";
        "bash" -> "coreutils";
    }
    
    // Build tools
    subgraph cluster_build {
        label="Build Tools";  
        color=green;
        "make" -> "build-essential";
        "pkg-config" -> "build-essential";
    }
    
    // System services
    subgraph cluster_system {
        label="System Services";
        color=blue;
        "systemd" -> "systemd-sysv";
        "udev" -> "systemd";
    }
    
    // Network tools
    subgraph cluster_network {
        label="Network";
        color=orange;
        "netbase" -> "iproute2";
        "iproute2" -> "iputils-ping";
        "iputils-ping" -> "openssh-server";
    }
    
    // Dependencies between clusters
    "coreutils" -> "make";
    "bash" -> "systemd";
    "base-files" -> "netbase";
}
EOF

# 실제 패키지들로 단순한 선형 그래프 생성
cat > "${BASE_DIR}/out/linear-build-graph.dot" << EOF
digraph LinearBuildOrder {
    rankdir=TB;
    node [shape=box, style=filled, fillcolor=lightgreen];
    
EOF

# 빌드 순서대로 연결
prev=""
while read -r pkg; do
    if [[ -n "$prev" ]]; then
        echo "    \"$prev\" -> \"$pkg\";" >> "${BASE_DIR}/out/linear-build-graph.dot"
    fi
    prev="$pkg"
done < "${BASE_DIR}/out/build-order.txt"

echo "}" >> "${BASE_DIR}/out/linear-build-graph.dot"

# 시각화 생성
echo "Generating visualizations..."

# 간단한 구조 그래프
dot -Tpng "${BASE_DIR}/out/simple-build-graph.dot" -o "${BASE_DIR}/out/simple-build-graph.png"
dot -Tsvg "${BASE_DIR}/out/simple-build-graph.dot" -o "${BASE_DIR}/out/simple-build-graph.svg"

# 선형 빌드 순서 그래프  
dot -Tpng -Grankdir=LR "${BASE_DIR}/out/linear-build-graph.dot" -o "${BASE_DIR}/out/linear-build-graph.png"
dot -Tsvg -Grankdir=LR "${BASE_DIR}/out/linear-build-graph.dot" -o "${BASE_DIR}/out/linear-build-graph.svg"

echo "Simple visualizations created:"
echo "  - Conceptual graph: ${BASE_DIR}/out/simple-build-graph.png"
echo "  - Linear build order: ${BASE_DIR}/out/linear-build-graph.png" 
echo "  - SVG versions also available"

ls -la "${BASE_DIR}/out/"*.png "${BASE_DIR}/out/"*.svg 2>/dev/null