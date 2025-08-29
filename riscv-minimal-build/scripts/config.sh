#!/usr/bin/env bash

# This file contains the central configuration for the entire build process.
# All other scripts should source this file to ensure consistency.

set -euo pipefail

# --- Build Target Configuration ---
export REL=${REL:-noble}
export ARCH=${ARCH:-riscv64}
export COMP=${COMP:-main}

# --- Project-specific Configuration ---
export REPO_KEY_ID="RISC-V Build <build@example.org>"

# --- Path Configuration ---
# Assumes all scripts are run from the project root directory.
export BASE_DIR=$(pwd)