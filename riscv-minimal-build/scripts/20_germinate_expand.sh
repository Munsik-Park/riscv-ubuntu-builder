#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

mkdir -p out

# Use a simple approach - directly process minimal.seed
echo "Processing minimal seed file..."
cd "${BASE_DIR}"

# For now, just copy the seed content as a starting point
grep -v '^#' seeds/minimal.seed | grep -v '^$' | awk '{print $1}' | sort -u > out/expanded-binaries.txt

echo "Generated $(wc -l < out/expanded-binaries.txt) packages from minimal seed"
wc -l out/expanded-binaries.txt
